//! Minimal file storage for file blocks: PUT raw bytes, GET by id. Token-authenticated.

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::state::AppState;

pub const MAX_FILE_BYTES: usize = 100 * 1024 * 1024;

#[derive(Deserialize)]
pub struct UploadQuery {
    pub name: String,
}

#[derive(Deserialize)]
pub struct TokenQuery {
    pub token: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub struct UploadResponse {
    pub file_id: String,
    pub name: String,
    pub size: usize,
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::to_string)
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
    !id.is_empty() && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

pub async fn upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<UploadQuery>,
    body: Bytes,
) -> Result<Json<UploadResponse>, (StatusCode, String)> {
    let uid = user_for(&state, bearer(&headers))?;
    let id = uuid::Uuid::new_v4().to_string();
    let dir = state.files_dir.join(&uid);
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    tokio::fs::write(dir.join(&id), &body)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(UploadResponse {
        file_id: id,
        name: q.name,
        size: body.len(),
    }))
}

pub async fn download(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(q): Query<TokenQuery>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let uid = user_for(&state, bearer(&headers).or(q.token))?;
    if !safe_id(&id) {
        return Err((StatusCode::BAD_REQUEST, "非法文件 id".into()));
    }
    let data = tokio::fs::read(state.files_dir.join(&uid).join(&id))
        .await
        .map_err(|_| (StatusCode::NOT_FOUND, "文件不存在".to_string()))?;
    Ok(([(header::CONTENT_TYPE, "application/octet-stream")], data))
}
