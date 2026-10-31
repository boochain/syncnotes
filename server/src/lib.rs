//! SyncNotes 1 protocol.
//!
//! Notes are opaque ciphertext. The server never sees plaintext.
//! Files are opaque bytes with a known length, written to disk before the response.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::body::Body;
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{DefaultBodyLimit, Path as UrlPath, Query, State, WebSocketUpgrade};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use bytes::Bytes;
use futures::StreamExt;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use uuid::Uuid;

pub const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_NOTE_CHARS: usize = 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    db: Arc<Mutex<Connection>>,
    files_dir: PathBuf,
    allow_register: bool,
    hub: Arc<Hub>,
}

struct Hub {
    next: AtomicU64,
    rooms: Mutex<HashMap<String, HashMap<u64, mpsc::UnboundedSender<String>>>>,
}

impl Hub {
    fn new() -> Self {
        Self { next: AtomicU64::new(1), rooms: Mutex::new(HashMap::new()) }
    }

    fn subscribe(&self, user: &str) -> (u64, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let mut rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        rooms.entry(user.to_string()).or_default().insert(id, tx);
        (id, rx)
    }

    fn unsubscribe(&self, user: &str, id: u64) {
        let mut rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(room) = rooms.get_mut(user) {
            room.remove(&id);
            if room.is_empty() {
                rooms.remove(user);
            }
        }
    }

    fn publish(&self, user: &str, msg: &str) {
        let mut dead = Vec::new();
        let rooms = self.rooms.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(room) = rooms.get(user) {
            for (id, tx) in room {
                if tx.send(msg.to_string()).is_err() {
                    dead.push(*id);
                }
            }
        }
        drop(rooms);
        for id in dead {
            self.unsubscribe(user, id);
        }
    }
}

impl AppState {
    pub fn open(db_path: &Path, files_dir: &Path, allow_register: bool) -> Result<Self, String> {
        if let Some(parent) = db_path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
        }
        std::fs::create_dir_all(files_dir).map_err(|e| e.to_string())?;
        let conn = Connection::open(db_path).map_err(|e| e.to_string())?;
        conn.execute_batch(
            "
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS users (
              id TEXT PRIMARY KEY,
              username TEXT UNIQUE NOT NULL,
              password_hash TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tokens (
              token TEXT PRIMARY KEY,
              user_id TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS notes (
              user_id TEXT NOT NULL,
              id TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              nonce TEXT NOT NULL,
              ciphertext TEXT NOT NULL,
              PRIMARY KEY (user_id, id)
            );
            CREATE TABLE IF NOT EXISTS files (
              id TEXT PRIMARY KEY,
              user_id TEXT NOT NULL,
              name TEXT NOT NULL,
              size INTEGER NOT NULL
            );
            ",
        )
        .map_err(|e| e.to_string())?;
        Ok(Self {
            db: Arc::new(Mutex::new(conn)),
            files_dir: files_dir.to_path_buf(),
            allow_register,
            hub: Arc::new(Hub::new()),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.db.lock().unwrap_or_else(|e| e.into_inner())
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/register", post(register))
        .route("/v1/login", post(login))
        .route("/v1/notes", get(list_notes))
        .route("/v1/notes/:id", put(put_note).delete(delete_note))
        .route("/v1/sync", get(sync_ws))
        .route("/v1/files", post(upload_file).layer(DefaultBodyLimit::disable()))
        .route("/v1/files/:id", get(download_file))
        .with_state(state)
}

pub async fn serve(state: AppState, addr: &str) -> Result<(), String> {
    let listener = tokio::net::TcpListener::bind(addr).await.map_err(|e| e.to_string())?;
    let bound = listener.local_addr().map_err(|e| e.to_string())?;
    tracing::info!("listening on {bound}");
    axum::serve(listener, router(state)).await.map_err(|e| e.to_string())
}

async fn health() -> Json<Value> {
    Json(json!({"ok": true, "protocol": 1, "version": env!("CARGO_PKG_VERSION")}))
}

#[derive(Deserialize)]
struct Creds {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct Session {
    token: String,
    user_id: String,
    username: String,
}

fn check_username(name: &str) -> Result<(), &'static str> {
    let n = name.trim();
    if n.is_empty() || n.chars().count() > 32 {
        return Err("用户名需要 1 到 32 个字符");
    }
    if n.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return Err("用户名不能包含空格");
    }
    Ok(())
}

fn check_password(pw: &str) -> Result<(), &'static str> {
    let n = pw.chars().count();
    if !(6..=128).contains(&n) {
        return Err("密码需要 6 到 128 个字符");
    }
    Ok(())
}

fn hash_password(pw: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(pw.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| e.to_string())
}

fn verify_password(pw: &str, hash: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(hash) else { return false };
    Argon2::default().verify_password(pw.as_bytes(), &parsed).is_ok()
}

fn err(code: StatusCode, msg: &str) -> axum::response::Response {
    (code, Json(json!({"error": msg}))).into_response()
}

async fn register(State(st): State<AppState>, Json(body): Json<Creds>) -> axum::response::Response {
    if !st.allow_register {
        return err(StatusCode::FORBIDDEN, "已关闭注册");
    }
    if let Err(m) = check_username(&body.username) {
        return err(StatusCode::BAD_REQUEST, m);
    }
    if let Err(m) = check_password(&body.password) {
        return err(StatusCode::BAD_REQUEST, m);
    }
    let username = body.username.trim().to_string();
    let hash = match hash_password(&body.password) {
        Ok(h) => h,
        Err(_) => return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误"),
    };
    let id = Uuid::new_v4().to_string();
    let token = Uuid::new_v4().to_string();
    let result = {
        let db = st.lock();
        db.execute("INSERT INTO users (id, username, password_hash) VALUES (?1, ?2, ?3)", params![id, username, hash])
    };
    match result {
        Ok(_) => {}
        Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
            return err(StatusCode::CONFLICT, "用户名已存在");
        }
        Err(_) => return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误"),
    }
    if st.lock().execute("INSERT INTO tokens (token, user_id) VALUES (?1, ?2)", params![token, id]).is_err() {
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    (StatusCode::OK, Json(Session { token, user_id: id, username })).into_response()
}

async fn login(State(st): State<AppState>, Json(body): Json<Creds>) -> axum::response::Response {
    let username = body.username.trim().to_string();
    let row: Result<(String, String), _> = {
        let db = st.lock();
        db.query_row(
            "SELECT id, password_hash FROM users WHERE username = ?1",
            params![username],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
    };
    let (id, hash) = match row {
        Ok(v) => v,
        Err(_) => return err(StatusCode::UNAUTHORIZED, "用户名或密码错误"),
    };
    if !verify_password(&body.password, &hash) {
        return err(StatusCode::UNAUTHORIZED, "用户名或密码错误");
    }
    let token = Uuid::new_v4().to_string();
    if st.lock().execute("INSERT INTO tokens (token, user_id) VALUES (?1, ?2)", params![token, id]).is_err() {
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    (StatusCode::OK, Json(Session { token, user_id: id, username })).into_response()
}

fn user_for(st: &AppState, headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let token = raw.strip_prefix("Bearer ").unwrap_or(raw).trim();
    if token.is_empty() {
        return None;
    }
    let db = st.lock();
    db.query_row("SELECT user_id FROM tokens WHERE token = ?1", params![token], |r| r.get(0)).ok()
}

#[derive(Serialize)]
struct NoteRow {
    id: String,
    updated_at: i64,
    nonce: String,
    ciphertext: String,
}

fn list_for(st: &AppState, user: &str) -> Result<Vec<NoteRow>, ()> {
    let db = st.lock();
    let mut stmt = db
        .prepare("SELECT id, updated_at, nonce, ciphertext FROM notes WHERE user_id = ?1 ORDER BY updated_at DESC")
        .map_err(|_| ())?;
    let rows = stmt
        .query_map(params![user], |r| {
            Ok(NoteRow { id: r.get(0)?, updated_at: r.get(1)?, nonce: r.get(2)?, ciphertext: r.get(3)? })
        })
        .map_err(|_| ())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|_| ())
}

async fn list_notes(State(st): State<AppState>, headers: HeaderMap) -> axum::response::Response {
    let Some(user) = user_for(&st, &headers) else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    match list_for(&st, &user) {
        Ok(notes) => Json(notes).into_response(),
        Err(()) => err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误"),
    }
}

#[derive(Deserialize)]
struct NoteIn {
    updated_at: i64,
    nonce: String,
    ciphertext: String,
}

fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 80 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn publish_note(st: &AppState, user: &str, note: &NoteRow) {
    if let Ok(msg) = serde_json::to_string(&json!({"op": "put", "note": note})) {
        st.hub.publish(user, &msg);
    }
}

async fn put_note(
    State(st): State<AppState>,
    headers: HeaderMap,
    UrlPath(id): UrlPath<String>,
    Json(body): Json<NoteIn>,
) -> axum::response::Response {
    let Some(user) = user_for(&st, &headers) else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    if !safe_id(&id) {
        return err(StatusCode::BAD_REQUEST, "非法笔记 id");
    }
    if body.updated_at < 0 || body.nonce.is_empty() || body.ciphertext.is_empty() {
        return err(StatusCode::BAD_REQUEST, "笔记格式错误");
    }
    if body.nonce.len() > 200 || body.ciphertext.len() > MAX_NOTE_CHARS {
        return err(StatusCode::PAYLOAD_TOO_LARGE, "笔记过大");
    }
    let existing: Option<i64> = {
        let db = st.lock();
        db.query_row("SELECT updated_at FROM notes WHERE user_id = ?1 AND id = ?2", params![user, id], |r| r.get(0))
            .ok()
    };
    if let Some(prev) = existing {
        if body.updated_at < prev {
            return err(StatusCode::CONFLICT, "服务器上有更新的版本");
        }
    }
    let saved = {
        let db = st.lock();
        db.execute(
            "INSERT INTO notes (user_id, id, updated_at, nonce, ciphertext) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(user_id, id) DO UPDATE SET updated_at = excluded.updated_at, nonce = excluded.nonce, ciphertext = excluded.ciphertext",
            params![user, id, body.updated_at, body.nonce, body.ciphertext],
        )
    };
    if saved.is_err() {
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    let note = NoteRow { id, updated_at: body.updated_at, nonce: body.nonce, ciphertext: body.ciphertext };
    publish_note(&st, &user, &note);
    Json(note).into_response()
}

async fn delete_note(State(st): State<AppState>, headers: HeaderMap, UrlPath(id): UrlPath<String>) -> axum::response::Response {
    let Some(user) = user_for(&st, &headers) else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    if !safe_id(&id) {
        return err(StatusCode::BAD_REQUEST, "非法笔记 id");
    }
    if st.lock().execute("DELETE FROM notes WHERE user_id = ?1 AND id = ?2", params![user, id]).is_err() {
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    if let Ok(msg) = serde_json::to_string(&json!({"op": "del", "id": id})) {
        st.hub.publish(&user, &msg);
    }
    StatusCode::NO_CONTENT.into_response()
}

#[derive(Deserialize)]
struct TokenQuery {
    token: String,
}

async fn sync_ws(State(st): State<AppState>, Query(q): Query<TokenQuery>, ws: WebSocketUpgrade) -> axum::response::Response {
    let user = {
        let db = st.lock();
        db.query_row("SELECT user_id FROM tokens WHERE token = ?1", params![q.token], |r| r.get::<_, String>(0)).ok()
    };
    let Some(user) = user else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    ws.on_upgrade(move |socket| async move { handle_socket(socket, st, user).await })
}

async fn handle_socket(mut socket: WebSocket, st: AppState, user: String) {
    let notes = list_for(&st, &user).unwrap_or_default();
    let hello = json!({"op": "snapshot", "notes": notes}).to_string();
    if socket.send(Message::Text(hello)).await.is_err() {
        return;
    }
    let (sub_id, mut rx) = st.hub.subscribe(&user);
    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if text.len() > MAX_NOTE_CHARS + 4096 {
                            break;
                        }
                        if apply_client_msg(&st, &user, &text).is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Ping(p))) => {
                        if socket.send(Message::Pong(p)).await.is_err() { break; }
                    }
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    _ => {}
                }
            }
            msg = rx.recv() => {
                match msg {
                    Some(text) => {
                        if socket.send(Message::Text(text)).await.is_err() { break; }
                    }
                    None => break,
                }
            }
        }
    }
    st.hub.unsubscribe(&user, sub_id);
}

fn apply_client_msg(st: &AppState, user: &str, text: &str) -> Result<(), ()> {
    let v: Value = serde_json::from_str(text).map_err(|_| ())?;
    let op = v.get("op").and_then(|x| x.as_str()).ok_or(())?;
    if op == "del" {
        let id = v.get("id").and_then(|x| x.as_str()).ok_or(())?;
        if !safe_id(id) {
            return Err(());
        }
        st.lock().execute("DELETE FROM notes WHERE user_id = ?1 AND id = ?2", params![user, id]).map_err(|_| ())?;
        if let Ok(msg) = serde_json::to_string(&json!({"op": "del", "id": id})) {
            st.hub.publish(user, &msg);
        }
        return Ok(());
    }
    if op != "put" {
        return Err(());
    }
    let id = v.get("id").and_then(|x| x.as_str()).ok_or(())?.to_string();
    let updated_at = v.get("updated_at").and_then(|x| x.as_i64()).ok_or(())?;
    let nonce = v.get("nonce").and_then(|x| x.as_str()).ok_or(())?.to_string();
    let ciphertext = v.get("ciphertext").and_then(|x| x.as_str()).ok_or(())?.to_string();
    if !safe_id(&id) || updated_at < 0 || nonce.is_empty() || ciphertext.is_empty() || ciphertext.len() > MAX_NOTE_CHARS {
        return Err(());
    }
    let existing: Option<i64> = st
        .lock()
        .query_row("SELECT updated_at FROM notes WHERE user_id = ?1 AND id = ?2", params![user, id], |r| r.get(0))
        .ok();
    if let Some(prev) = existing {
        if updated_at < prev {
            return Ok(());
        }
    }
    st.lock()
        .execute(
            "INSERT INTO notes (user_id, id, updated_at, nonce, ciphertext) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(user_id, id) DO UPDATE SET updated_at = excluded.updated_at, nonce = excluded.nonce, ciphertext = excluded.ciphertext",
            params![user, id, updated_at, nonce, ciphertext],
        )
        .map_err(|_| ())?;
    publish_note(st, user, &NoteRow { id, updated_at, nonce, ciphertext });
    Ok(())
}

fn file_name(headers: &HeaderMap) -> String {
    let Some(raw) = headers.get("x-file-name").and_then(|v| v.to_str().ok()) else {
        return "file".to_string();
    };
    let bytes = URL_SAFE_NO_PAD.decode(raw).unwrap_or_default();
    let name = String::from_utf8(bytes).unwrap_or_default();
    let name = name.rsplit(['/', '\\']).next().unwrap_or("file").trim();
    let name: String = name.chars().filter(|c| !c.is_control()).take(180).collect();
    if name.is_empty() { "file".to_string() } else { name }
}

async fn upload_file(State(st): State<AppState>, headers: HeaderMap, body: Body) -> axum::response::Response {
    let Some(user) = user_for(&st, &headers) else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    let name = file_name(&headers);
    let id = Uuid::new_v4().to_string();
    let dir = st.files_dir.join(&user);
    if tokio::fs::create_dir_all(&dir).await.is_err() {
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    let tmp = dir.join(format!("{id}.part"));
    let final_path = dir.join(&id);
    let mut file = match tokio::fs::File::create(&tmp).await {
        Ok(f) => f,
        Err(_) => return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误"),
    };
    let mut stream = body.into_data_stream();
    let mut got: u64 = 0;
    let mut failed: Option<&'static str> = None;
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(_) => {
                failed = Some("连接中断");
                break;
            }
        };
        got += chunk.len() as u64;
        if got > MAX_FILE_BYTES {
            failed = Some("文件过大");
            break;
        }
        if file.write_all(&chunk).await.is_err() {
            failed = Some("写入失败");
            break;
        }
    }
    if let Some(msg) = failed {
        drop(file);
        let _ = tokio::fs::remove_file(&tmp).await;
        let code = if msg == "文件过大" { StatusCode::PAYLOAD_TOO_LARGE } else { StatusCode::BAD_REQUEST };
        return err(code, msg);
    }
    if file.flush().await.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
        return err(StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
    }
    drop(file);
    if tokio::fs::rename(&tmp, &final_path).await.is_err() {
        let _ = tokio::fs::remove_file(&tmp).await;
        return err(StatusCode::INTERNAL_SERVER_ERROR, "写入失败");
    }
    let size = i64::try_from(got).unwrap_or(i64::MAX);
    if st.lock().execute("INSERT INTO files (id, user_id, name, size) VALUES (?1, ?2, ?3, ?4)", params![id, user, name, size]).is_err()
    {
        let _ = tokio::fs::remove_file(&final_path).await;
        return err(StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误");
    }
    Json(json!({"id": id, "name": name, "size": got})).into_response()
}

async fn download_file(State(st): State<AppState>, headers: HeaderMap, UrlPath(id): UrlPath<String>) -> axum::response::Response {
    let Some(user) = user_for(&st, &headers) else {
        return err(StatusCode::UNAUTHORIZED, "无效令牌");
    };
    if !safe_id(&id) {
        return err(StatusCode::BAD_REQUEST, "非法文件 id");
    }
    let name: String = {
        let db = st.lock();
        match db.query_row("SELECT name FROM files WHERE id = ?1 AND user_id = ?2", params![id, user], |r| r.get(0)) {
            Ok(n) => n,
            Err(_) => return err(StatusCode::NOT_FOUND, "文件不存在"),
        }
    };
    let path = st.files_dir.join(&user).join(&id);
    let file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(_) => return err(StatusCode::NOT_FOUND, "文件不存在"),
    };
    let len = file.metadata().await.map(|m| m.len()).unwrap_or(0);
    let stream = futures::stream::unfold(file, |mut file| async move {
        let mut buf = vec![0u8; 64 * 1024];
        match file.read(&mut buf).await {
            Ok(0) => None,
            Ok(n) => {
                buf.truncate(n);
                Some((Ok::<Bytes, std::io::Error>(Bytes::from(buf)), file))
            }
            Err(e) => Some((Err(e), file)),
        }
    });
    let encoded = URL_SAFE_NO_PAD.encode(name.as_bytes());
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_string()),
            (header::CONTENT_LENGTH, len.to_string()),
            (header::HeaderName::from_static("x-file-name"), encoded),
        ],
        Body::from_stream(stream),
    )
        .into_response()
}
