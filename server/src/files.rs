//! File bytes move as a stream of sealed chunks (`POST /api/blob`).
//! The server never buffers a whole file: each chunk is decrypted and written
//! before the next one is read. Plaintext PUT/GET are rejected at the router.
//!
//! Supports both single-request uploads/downloads (`put`, `get`) and resumable
//! chunked transfers (`put_init`, `put_part`, `put_finish`, `put_abort`, and
//! range `get` with `offset`/`length`) so slow or lossy public networks never
//! stall indefinitely or restart large files from 0%.

use std::io::SeekFrom;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::time::{Duration, SystemTime};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use bytes::BytesMut;
use futures::{SinkExt, Stream, StreamExt};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufReader, BufWriter};

use crate::seal::{open_chunk, seal_chunk, OpenedHttp, CHUNK, MAX_CHUNK};
use crate::state::AppState;

/// 明文上限 4 GiB。加密后的 HTTP 体还要加上每块的长度和校验，那一层用 [max_http_body]。
pub const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024 * 1024;

/// 断点续传默认分片大小：4 MiB（公网几 MB/s 环境下 1~2 秒一个分片，避免反代超时与长连接卡死）。
pub const RESUME_PART_BYTES: u64 = 4 * 1024 * 1024;

/// 单块读写停顿超时：30 秒无数据即判定链路卡死，快速失败以便客户端立即断点续传。
const IO_STALL_TIMEOUT: Duration = Duration::from_secs(30);

/// 过期未完成的临时上传分片保留时长（24 小时）。
const STALE_UPLOAD_TTL: Duration = Duration::from_secs(24 * 3600);

pub fn max_http_body() -> usize {
    let chunks = MAX_FILE_BYTES.div_ceil(CHUNK as u64);
    let extra = 4 + 64 * 1024 + chunks * (4 + 16) + 4;
    (MAX_FILE_BYTES + extra) as usize
}

/// Ensures `.part` upload files are deleted even if the HTTP request task is cancelled mid-stream.
struct TempFileGuard {
    path: PathBuf,
    armed: bool,
}

impl TempFileGuard {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        if self.armed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn user_for(state: &AppState, token: Option<String>) -> Result<String, (StatusCode, String)> {
    let t = token.ok_or((StatusCode::UNAUTHORIZED, "缺少令牌".to_string()))?;
    state
        .storage
        .validate_token(&t)
        .ok()
        .flatten()
        .map(|(uid, _)| uid)
        .ok_or((StatusCode::UNAUTHORIZED, "无效令牌".to_string()))
}

fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 80 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

struct Reader {
    stream: Pin<Box<dyn Stream<Item = Result<axum::body::Bytes, axum::Error>> + Send>>,
    buf: BytesMut,
}

impl Reader {
    fn new(body: Body) -> Self {
        Self {
            stream: Box::pin(body.into_data_stream()),
            buf: BytesMut::new(),
        }
    }

    async fn fill(&mut self, n: usize) -> Result<(), ()> {
        while self.buf.len() < n {
            match tokio::time::timeout(IO_STALL_TIMEOUT, self.stream.next()).await {
                Ok(Some(Ok(b))) if !b.is_empty() => self.buf.extend_from_slice(&b),
                Ok(Some(Ok(_))) => continue,
                _ => return Err(()),
            }
        }
        Ok(())
    }

    async fn u32(&mut self) -> Result<u32, ()> {
        self.fill(4).await?;
        let n = u32::from_be_bytes(self.buf[..4].try_into().unwrap());
        let _ = self.buf.split_to(4);
        Ok(n)
    }

    async fn take(&mut self, n: usize) -> Result<Vec<u8>, ()> {
        self.fill(n).await?;
        Ok(self.buf.split_to(n).to_vec())
    }
}

#[derive(Deserialize)]
struct BlobMeta {
    op: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    size: u64,
    token: String,
    #[serde(default)]
    file_id: String,
    #[serde(default)]
    sha256: String,
    #[serde(default)]
    upload_id: String,
    #[serde(default)]
    offset: u64,
    #[serde(default)]
    length: u64,
}

fn sealed(opened: &OpenedHttp, status: u16, body: &[u8]) -> axum::response::Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/octet-stream")],
        opened.seal_response(status, body),
    )
        .into_response()
}

fn sealed_err(opened: &OpenedHttp, status: StatusCode, msg: &str) -> axum::response::Response {
    sealed(opened, status.as_u16(), msg.as_bytes())
}

fn hex32(bytes: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(H[(b >> 4) as usize] as char);
        out.push(H[(b & 0xf) as usize] as char);
    }
    out
}

/// Read chunk frames until the terminator so the HTTP request body is finished
/// before we write a response. Dropping an unread body makes hyper reset the
/// socket ("connection closed") and the client never sees the error.
async fn discard_chunks(reader: &mut Reader) {
    loop {
        let cn = match reader.u32().await {
            Ok(v) => v,
            Err(()) => return,
        };
        if cn == 0 {
            return;
        }
        if cn as usize > MAX_CHUNK + 16 {
            return;
        }
        if reader.take(cn as usize).await.is_err() {
            return;
        }
    }
}

/// Best-effort cleanup of abandoned `.uploads/*.part` files older than 24h.
async fn cleanup_stale_uploads(uploads_dir: &Path) {
    let Ok(mut entries) = tokio::fs::read_dir(uploads_dir).await else {
        return;
    };
    let now = SystemTime::now();
    while let Ok(Some(entry)) = entries.next_entry().await {
        let Ok(meta) = entry.metadata().await else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        if now.duration_since(modified).unwrap_or_default() > STALE_UPLOAD_TTL {
            let _ = tokio::fs::remove_file(entry.path()).await;
        }
    }
}

/// Compute SHA-256 and exact byte length of a file on a blocking worker thread
/// so Tokio async workers stay responsive during large-file finalization.
async fn hash_file_blocking(path: PathBuf) -> Result<(u64, String), std::io::Error> {
    tokio::task::spawn_blocking(move || {
        use std::io::Read;
        let mut f = std::fs::File::open(&path)?;
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1024 * 1024];
        let mut total = 0u64;
        loop {
            let n = f.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            total += n as u64;
        }
        Ok((total, hex32(&hasher.finalize())))
    })
    .await
    .map_err(|_| std::io::Error::other("hash task failed"))?
}

async fn stream_file_then(
    opened: &OpenedHttp,
    path: PathBuf,
    header_body: Vec<u8>,
    delete_after: bool,
) -> axum::response::Response {
    let raw_file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(_) => {
            if delete_after {
                let _ = tokio::fs::remove_file(&path).await;
            }
            return sealed_err(opened, StatusCode::NOT_FOUND, "文件不存在");
        }
    };
    let size = raw_file.metadata().await.map(|m| m.len()).unwrap_or(0);
    let key = opened.chunk_key();
    let head = opened.seal_response(200, &header_body);
    let (mut tx, rx) =
        futures::channel::mpsc::channel::<Result<axum::body::Bytes, std::io::Error>>(16);
    let path_del = path.clone();
    tokio::spawn(async move {
        let mut prefix = Vec::with_capacity(4 + head.len());
        prefix.extend_from_slice(&(head.len() as u32).to_be_bytes());
        prefix.extend_from_slice(&head);
        if !matches!(
            tokio::time::timeout(
                IO_STALL_TIMEOUT,
                tx.send(Ok(axum::body::Bytes::from(prefix)))
            )
            .await,
            Ok(Ok(()))
        ) {
            if delete_after {
                let _ = tokio::fs::remove_file(&path_del).await;
            }
            return;
        }
        let mut file = BufReader::with_capacity(512 * 1024, raw_file);
        let mut buf = vec![0u8; CHUNK];
        let mut idx = 0u64;
        let mut left = size;
        while left > 0 {
            let target = (CHUNK as u64).min(left) as usize;
            let mut filled = 0usize;
            while filled < target {
                match file.read(&mut buf[filled..target]).await {
                    Ok(0) => break,
                    Ok(n) => filled += n,
                    Err(_) => {
                        if delete_after {
                            let _ = tokio::fs::remove_file(&path_del).await;
                        }
                        return;
                    }
                }
            }
            if filled == 0 {
                break;
            }
            left -= filled as u64;
            let ct = seal_chunk(&key, idx, &buf[..filled]);
            let mut frame = Vec::with_capacity(4 + ct.len());
            frame.extend_from_slice(&(ct.len() as u32).to_be_bytes());
            frame.extend_from_slice(&ct);
            match tokio::time::timeout(
                IO_STALL_TIMEOUT,
                tx.send(Ok(axum::body::Bytes::from(frame))),
            )
            .await
            {
                Ok(Ok(())) => {}
                _ => {
                    if delete_after {
                        let _ = tokio::fs::remove_file(&path_del).await;
                    }
                    return;
                }
            }
            idx += 1;
        }
        let _ = tokio::time::timeout(
            IO_STALL_TIMEOUT,
            tx.send(Ok(axum::body::Bytes::from(0u32.to_be_bytes().to_vec()))),
        )
        .await;
        drop(tx);
        if delete_after {
            let _ = tokio::fs::remove_file(&path_del).await;
        }
    });
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/octet-stream")],
        Body::from_stream(rx),
    )
        .into_response()
}

/// Streamed encrypted upload or download (including resumable chunked transfers).
pub async fn blob(State(state): State<AppState>, body: Body) -> axum::response::Response {
    let mut reader = Reader::new(body);
    let n = match reader.u32().await {
        Ok(n) if n as usize <= 64 * 1024 => n as usize,
        _ => return (StatusCode::BAD_REQUEST, "加密通道无效").into_response(),
    };
    let header = match reader.take(n).await {
        Ok(b) => b,
        Err(()) => return (StatusCode::BAD_REQUEST, "加密通道无效").into_response(),
    };
    let opened = match OpenedHttp::open(&state.seal, &header) {
        Ok(v) => v,
        Err(()) => return (StatusCode::BAD_REQUEST, "加密通道无效").into_response(),
    };
    let meta: BlobMeta = match serde_json::from_slice(&opened.body) {
        Ok(v) => v,
        Err(_) => {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误");
        }
    };
    let uid = match user_for(&state, Some(meta.token.clone())) {
        Ok(u) => u,
        Err((c, m)) => {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, c, &m);
        }
    };
    let key = opened.chunk_key();

    // ── Resumable chunked upload: init ────────────────────────────────────────
    if meta.op == "put_init" {
        match reader.u32().await {
            Ok(0) => {}
            _ => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
        }
        if meta.size > MAX_FILE_BYTES {
            return sealed_err(&opened, StatusCode::PAYLOAD_TOO_LARGE, "文件过大");
        }
        let uploads_dir = state.files_dir.join(&uid).join(".uploads");
        if tokio::fs::create_dir_all(&uploads_dir).await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
        }
        cleanup_stale_uploads(&uploads_dir).await;

        if !meta.upload_id.is_empty() && safe_id(&meta.upload_id) {
            let existing = uploads_dir.join(format!("{}.part", meta.upload_id));
            if let Ok(m) = tokio::fs::metadata(&existing).await {
                let offset = m.len();
                let body = serde_json::to_vec(&json!({
                    "upload_id": meta.upload_id,
                    "offset": offset,
                    "part_size": RESUME_PART_BYTES,
                }))
                .unwrap_or_default();
                return sealed(&opened, 200, &body);
            }
        }

        let upload_id = uuid::Uuid::new_v4().to_string();
        let part_path = uploads_dir.join(format!("{upload_id}.part"));
        if tokio::fs::File::create(&part_path).await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
        }
        let body = serde_json::to_vec(&json!({
            "upload_id": upload_id,
            "offset": 0u64,
            "part_size": RESUME_PART_BYTES,
        }))
        .unwrap_or_default();
        return sealed(&opened, 200, &body);
    }

    // ── Resumable chunked upload: append/overwrite part at offset ─────────────
    if meta.op == "put_part" {
        if !safe_id(&meta.upload_id) {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "非法上传 id");
        }
        if meta.offset > MAX_FILE_BYTES
            || meta.length > MAX_FILE_BYTES
            || meta.offset.saturating_add(meta.length) > MAX_FILE_BYTES
        {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::PAYLOAD_TOO_LARGE, "文件过大");
        }
        let part_path = state
            .files_dir
            .join(&uid)
            .join(".uploads")
            .join(format!("{}.part", meta.upload_id));
        let mut raw_file = match tokio::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&part_path)
            .await
        {
            Ok(f) => f,
            Err(_) => {
                discard_chunks(&mut reader).await;
                return sealed_err(&opened, StatusCode::NOT_FOUND, "上传会话不存在或已过期");
            }
        };
        let cur_len = raw_file.metadata().await.map(|m| m.len()).unwrap_or(0);
        if meta.offset > cur_len {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::CONFLICT, "分片偏移量不连续");
        }
        if raw_file.seek(SeekFrom::Start(meta.offset)).await.is_err() {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        let mut file = BufWriter::with_capacity(512 * 1024, raw_file);
        let mut idx = 0u64;
        let mut got: u64 = 0;
        let outcome = loop {
            let cn = match reader.u32().await {
                Ok(v) => v,
                Err(()) => break Err("连接中断"),
            };
            if cn == 0 {
                break Ok(());
            }
            if cn as usize > MAX_CHUNK + 16 {
                break Err("分块过大");
            }
            let ct = match reader.take(cn as usize).await {
                Ok(v) => v,
                Err(()) => break Err("连接中断"),
            };
            let plain = match open_chunk(&key, idx, &ct) {
                Ok(v) => v,
                Err(()) => break Err("分块校验失败"),
            };
            got += plain.len() as u64;
            if meta.offset.saturating_add(got) > MAX_FILE_BYTES {
                break Err("文件过大");
            }
            if file.write_all(&plain).await.is_err() {
                break Err("写入失败");
            }
            idx += 1;
        };
        if let Err(msg) = outcome {
            drop(file);
            discard_chunks(&mut reader).await;
            let code = if msg == "文件过大" {
                StatusCode::PAYLOAD_TOO_LARGE
            } else {
                StatusCode::BAD_REQUEST
            };
            return sealed_err(&opened, code, msg);
        }
        if meta.length != 0 && got != meta.length {
            drop(file);
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "分片长度不符");
        }
        if file.flush().await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        let new_offset = meta.offset + got;
        let raw_file = file.into_inner();
        if new_offset < cur_len {
            let _ = raw_file.set_len(new_offset).await;
        }
        let body = serde_json::to_vec(&json!({
            "upload_id": meta.upload_id,
            "offset": new_offset,
            "written": got,
        }))
        .unwrap_or_default();
        return sealed(&opened, 200, &body);
    }

    // ── Resumable chunked upload: finalize & verify SHA-256 ───────────────────
    if meta.op == "put_finish" {
        match reader.u32().await {
            Ok(0) => {}
            _ => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
        }
        if !safe_id(&meta.upload_id) {
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "非法上传 id");
        }
        let dir = state.files_dir.join(&uid);
        let part_path = dir
            .join(".uploads")
            .join(format!("{}.part", meta.upload_id));
        if tokio::fs::metadata(&part_path).await.is_err() {
            return sealed_err(&opened, StatusCode::NOT_FOUND, "上传会话不存在或已过期");
        }
        let (got, sha) = match hash_file_blocking(part_path.clone()).await {
            Ok(v) => v,
            Err(_) => {
                return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "文件校验失败");
            }
        };
        if meta.size != 0 && got != meta.size {
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "文件长度不符");
        }
        if !meta.sha256.is_empty() && meta.sha256 != sha {
            let _ = tokio::fs::remove_file(&part_path).await;
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "文件校验失败");
        }
        let id = uuid::Uuid::new_v4().to_string();
        let final_path = dir.join(&id);
        let hash_path = dir.join(format!("{id}.sha256"));
        if tokio::fs::write(&hash_path, sha.as_bytes()).await.is_err()
            || tokio::fs::rename(&part_path, &final_path).await.is_err()
        {
            let _ = tokio::fs::remove_file(&hash_path).await;
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        let body = serde_json::to_vec(&json!({
            "file_id": id,
            "name": meta.name,
            "size": got,
            "sha256": sha,
        }))
        .unwrap_or_default();
        return sealed(&opened, 200, &body);
    }

    // ── Resumable chunked upload: abort & cleanup ─────────────────────────────
    if meta.op == "put_abort" {
        match reader.u32().await {
            Ok(0) => {}
            _ => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
        }
        if safe_id(&meta.upload_id) {
            let part_path = state
                .files_dir
                .join(&uid)
                .join(".uploads")
                .join(format!("{}.part", meta.upload_id));
            let _ = tokio::fs::remove_file(&part_path).await;
        }
        let body = serde_json::to_vec(&json!({"ok": true})).unwrap_or_default();
        return sealed(&opened, 200, &body);
    }

    // ── Legacy single-request streamed upload (kept for small files & older clients)
    if meta.op == "put" {
        if meta.size > MAX_FILE_BYTES {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::PAYLOAD_TOO_LARGE, "文件过大");
        }
        let id = uuid::Uuid::new_v4().to_string();
        let dir = state.files_dir.join(&uid);
        if tokio::fs::create_dir_all(&dir).await.is_err() {
            discard_chunks(&mut reader).await;
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
        }
        let tmp = dir.join(format!("{id}.part"));
        let final_path = dir.join(&id);
        let hash_path = dir.join(format!("{id}.sha256"));
        let mut tmp_guard = TempFileGuard::new(tmp.clone());
        let raw_file = match tokio::fs::File::create(&tmp).await {
            Ok(f) => f,
            Err(_) => {
                discard_chunks(&mut reader).await;
                return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
            }
        };
        let mut file = BufWriter::with_capacity(1024 * 1024, raw_file);
        let mut hasher = Sha256::new();
        let mut idx = 0u64;
        let mut got: u64 = 0;
        let outcome = loop {
            let cn = match reader.u32().await {
                Ok(v) => v,
                Err(()) => break Err("连接中断"),
            };
            if cn == 0 {
                break Ok(());
            }
            if cn as usize > MAX_CHUNK + 16 {
                break Err("分块过大");
            }
            let ct = match reader.take(cn as usize).await {
                Ok(v) => v,
                Err(()) => break Err("连接中断"),
            };
            let plain = match open_chunk(&key, idx, &ct) {
                Ok(v) => v,
                Err(()) => break Err("分块校验失败"),
            };
            got += plain.len() as u64;
            if got > MAX_FILE_BYTES {
                break Err("文件过大");
            }
            hasher.update(&plain);
            if file.write_all(&plain).await.is_err() {
                break Err("写入失败");
            }
            idx += 1;
        };
        if let Err(msg) = outcome {
            drop(file);
            let _ = tokio::fs::remove_file(&tmp).await;
            tmp_guard.disarm();
            discard_chunks(&mut reader).await;
            let code = if msg == "文件过大" {
                StatusCode::PAYLOAD_TOO_LARGE
            } else {
                StatusCode::BAD_REQUEST
            };
            return sealed_err(&opened, code, msg);
        }
        if meta.size != 0 && got != meta.size {
            drop(file);
            let _ = tokio::fs::remove_file(&tmp).await;
            tmp_guard.disarm();
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "文件长度不符");
        }
        let sha = hex32(&hasher.finalize());
        if !meta.sha256.is_empty() && meta.sha256 != sha {
            drop(file);
            let _ = tokio::fs::remove_file(&tmp).await;
            tmp_guard.disarm();
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "文件校验失败");
        }
        if file.flush().await.is_err() {
            drop(file);
            let _ = tokio::fs::remove_file(&tmp).await;
            tmp_guard.disarm();
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        drop(file);
        if tokio::fs::write(&hash_path, sha.as_bytes()).await.is_err()
            || tokio::fs::rename(&tmp, &final_path).await.is_err()
        {
            let _ = tokio::fs::remove_file(&tmp).await;
            let _ = tokio::fs::remove_file(&hash_path).await;
            tmp_guard.disarm();
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        tmp_guard.disarm();
        let body = serde_json::to_vec(&json!({
            "file_id": id,
            "name": meta.name,
            "size": got,
            "sha256": sha,
        }))
        .unwrap_or_default();
        return sealed(&opened, 200, &body);
    }

    // ── Streamed download with optional resumable range (`offset` / `length`) ─
    if meta.op == "get" {
        // The client ends the request with a 0-length frame. Read it before
        // responding, or the unread tail resets the connection mid-download.
        match reader.u32().await {
            Ok(0) => {}
            _ => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
        }
        if !safe_id(&meta.file_id) {
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "非法文件 id");
        }
        let path = state.files_dir.join(&uid).join(&meta.file_id);
        let mut raw_file = match tokio::fs::File::open(&path).await {
            Ok(f) => f,
            Err(_) => return sealed_err(&opened, StatusCode::NOT_FOUND, "文件不存在"),
        };
        let size = raw_file.metadata().await.map(|m| m.len()).unwrap_or(0);
        if meta.offset > size {
            return sealed_err(
                &opened,
                StatusCode::RANGE_NOT_SATISFIABLE,
                "偏移量超出文件大小",
            );
        }
        if meta.offset > 0 && raw_file.seek(SeekFrom::Start(meta.offset)).await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "读取失败");
        }
        let remaining_total = if meta.length > 0 {
            meta.length.min(size - meta.offset)
        } else {
            size - meta.offset
        };
        let sha = tokio::fs::read_to_string(
            state
                .files_dir
                .join(&uid)
                .join(format!("{}.sha256", meta.file_id)),
        )
        .await
        .unwrap_or_default();
        let head = opened.seal_response(
            200,
            &serde_json::to_vec(&json!({
                "size": size,
                "offset": meta.offset,
                "length": remaining_total,
                "name": meta.name,
                "sha256": sha.trim(),
            }))
            .unwrap_or_default(),
        );
        let (mut tx, rx) =
            futures::channel::mpsc::channel::<Result<axum::body::Bytes, std::io::Error>>(16);
        tokio::spawn(async move {
            let mut prefix = Vec::with_capacity(4 + head.len());
            prefix.extend_from_slice(&(head.len() as u32).to_be_bytes());
            prefix.extend_from_slice(&head);
            if !matches!(
                tokio::time::timeout(
                    IO_STALL_TIMEOUT,
                    tx.send(Ok(axum::body::Bytes::from(prefix)))
                )
                .await,
                Ok(Ok(()))
            ) {
                return;
            }
            let mut file = BufReader::with_capacity(512 * 1024, raw_file);
            let mut buf = vec![0u8; CHUNK];
            let mut idx = 0u64;
            let mut left = remaining_total;
            while left > 0 {
                let target = (CHUNK as u64).min(left) as usize;
                let mut filled = 0usize;
                while filled < target {
                    match file.read(&mut buf[filled..target]).await {
                        Ok(0) => break,
                        Ok(n) => filled += n,
                        Err(_) => return,
                    }
                }
                if filled == 0 {
                    break;
                }
                left -= filled as u64;
                let ct = seal_chunk(&key, idx, &buf[..filled]);
                let mut frame = Vec::with_capacity(4 + ct.len());
                frame.extend_from_slice(&(ct.len() as u32).to_be_bytes());
                frame.extend_from_slice(&ct);
                match tokio::time::timeout(
                    IO_STALL_TIMEOUT,
                    tx.send(Ok(axum::body::Bytes::from(frame))),
                )
                .await
                {
                    Ok(Ok(())) => {}
                    _ => return,
                }
                idx += 1;
            }
            let _ = tokio::time::timeout(
                IO_STALL_TIMEOUT,
                tx.send(Ok(axum::body::Bytes::from(0u32.to_be_bytes().to_vec()))),
            )
            .await;
        });
        return (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "application/octet-stream")],
            Body::from_stream(rx),
        )
            .into_response();
    }

    // ── Account backup zip (server content the user can see) ─────────────────
    if meta.op == "backup_export" {
        match reader.u32().await {
            Ok(0) => {}
            _ => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
        }
        let user = match state.storage.find_user_by_id(&uid) {
            Ok(Some(u)) => u,
            _ => return sealed_err(&opened, StatusCode::UNAUTHORIZED, "无效令牌"),
        };
        let exports_dir = state.files_dir.join(&uid).join(".exports");
        if tokio::fs::create_dir_all(&exports_dir).await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
        }
        let tmp = exports_dir.join(format!("export-{}.zip", uuid::Uuid::new_v4()));
        let storage = state.storage.clone();
        let files_dir = state.files_dir.clone();
        let username = user.username.clone();
        let tmp_task = tmp.clone();
        let built = tokio::task::spawn_blocking(move || {
            crate::admin::export_user(&storage, &files_dir, &username, &tmp_task)
        })
        .await;
        match built {
            Ok(Ok(sum)) => {
                let header = serde_json::to_vec(&json!({
                    "name": "syncnotes-backup.zip",
                    "size": tokio::fs::metadata(&tmp).await.map(|m| m.len()).unwrap_or(0),
                    "blocks": sum.blocks,
                    "trashed": sum.trashed,
                    "files": sum.files,
                    "missing_files": sum.missing_files,
                }))
                .unwrap_or_default();
                return stream_file_then(&opened, tmp, header, true).await;
            }
            Ok(Err(e)) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, &e);
            }
            Err(_) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "导出失败");
            }
        }
    }

    discard_chunks(&mut reader).await;
    sealed_err(&opened, StatusCode::BAD_REQUEST, "未知操作")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_four_gib() {
        assert_eq!(MAX_FILE_BYTES, 4 * 1024 * 1024 * 1024);
        let body = max_http_body() as u64;
        assert!(body > MAX_FILE_BYTES);
        assert!(body < MAX_FILE_BYTES + 8 * 1024 * 1024);
    }
}
