//! File bytes move as a stream of sealed chunks (`POST /api/blob`).
//! The server never buffers a whole file: each chunk is decrypted and written
//! before the next one is read. Plaintext PUT/GET are rejected at the router.

use std::pin::Pin;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::IntoResponse;
use bytes::BytesMut;
use futures::{SinkExt, Stream, StreamExt};
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::seal::{open_chunk, seal_chunk, OpenedHttp, CHUNK, MAX_CHUNK};
use crate::state::AppState;

pub const MAX_FILE_BYTES: usize = 100 * 1024 * 1024;

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
            match self.stream.next().await {
                Some(Ok(b)) if !b.is_empty() => self.buf.extend_from_slice(&b),
                Some(Ok(_)) => continue,
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

/// Streamed encrypted upload or download.
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
        Err(_) => return sealed_err(&opened, StatusCode::BAD_REQUEST, "请求格式错误"),
    };
    let uid = match user_for(&state, Some(meta.token.clone())) {
        Ok(u) => u,
        Err((c, m)) => return sealed_err(&opened, c, &m),
    };
    let key = opened.chunk_key();
    if meta.op == "put" {
        // Drain the chunk stream straight onto disk.
        if meta.size > MAX_FILE_BYTES as u64 {
            // Still consume nothing more; tell the client and drop the body.
            return sealed_err(&opened, StatusCode::PAYLOAD_TOO_LARGE, "文件过大");
        }
        let id = uuid::Uuid::new_v4().to_string();
        let dir = state.files_dir.join(&uid);
        if tokio::fs::create_dir_all(&dir).await.is_err() {
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
        }
        let tmp = dir.join(format!("{id}.part"));
        let final_path = dir.join(&id);
        let mut file = match tokio::fs::File::create(&tmp).await {
            Ok(f) => f,
            Err(_) => {
                return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误")
            }
        };
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
            if got > MAX_FILE_BYTES as u64 {
                break Err("文件过大");
            }
            if file.write_all(&plain).await.is_err() {
                break Err("写入失败");
            }
            idx += 1;
        };
        if let Err(msg) = outcome {
            drop(file);
            let _ = tokio::fs::remove_file(&tmp).await;
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
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "文件长度不符");
        }
        if file.flush().await.is_err() {
            let _ = tokio::fs::remove_file(&tmp).await;
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        drop(file);
        if tokio::fs::rename(&tmp, &final_path).await.is_err() {
            let _ = tokio::fs::remove_file(&tmp).await;
            return sealed_err(&opened, StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
        }
        let body = serde_json::to_vec(&json!({
            "file_id": id,
            "name": meta.name,
            "size": got,
        }))
        .unwrap_or_default();
        return sealed(&opened, 200, &body);
    }
    if meta.op == "get" {
        if !safe_id(&meta.file_id) {
            return sealed_err(&opened, StatusCode::BAD_REQUEST, "非法文件 id");
        }
        let path = state.files_dir.join(&uid).join(&meta.file_id);
        let mut file = match tokio::fs::File::open(&path).await {
            Ok(f) => f,
            Err(_) => return sealed_err(&opened, StatusCode::NOT_FOUND, "文件不存在"),
        };
        let size = file.metadata().await.map(|m| m.len()).unwrap_or(0);
        let head = opened.seal_response(
            200,
            &serde_json::to_vec(&json!({"size": size, "name": meta.name})).unwrap_or_default(),
        );
        let (mut tx, rx) =
            futures::channel::mpsc::channel::<Result<axum::body::Bytes, std::io::Error>>(2);
        tokio::spawn(async move {
            let mut prefix = Vec::with_capacity(4 + head.len());
            prefix.extend_from_slice(&(head.len() as u32).to_be_bytes());
            prefix.extend_from_slice(&head);
            if tx.send(Ok(axum::body::Bytes::from(prefix))).await.is_err() {
                return;
            }
            let mut buf = vec![0u8; CHUNK];
            let mut idx = 0u64;
            loop {
                let n = match file.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => return,
                };
                let ct = seal_chunk(&key, idx, &buf[..n]);
                let mut frame = Vec::with_capacity(4 + ct.len());
                frame.extend_from_slice(&(ct.len() as u32).to_be_bytes());
                frame.extend_from_slice(&ct);
                if tx.send(Ok(axum::body::Bytes::from(frame))).await.is_err() {
                    return;
                }
                idx += 1;
            }
            let _ = tx
                .send(Ok(axum::body::Bytes::from(0u32.to_be_bytes().to_vec())))
                .await;
        });
        return (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "application/octet-stream")],
            Body::from_stream(rx),
        )
            .into_response();
    }
    sealed_err(&opened, StatusCode::BAD_REQUEST, "未知操作")
}
