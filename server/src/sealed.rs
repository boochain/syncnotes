//! `POST /api/seal` — the only JSON API. The body is a syncnotes-seal-v1 envelope.
//! The real status code lives inside the ciphertext; the HTTP status is 200 so
//! the wire does not echo plaintext. Crypto failure is a static 400.

use axum::async_trait;
use axum::body::Bytes;
use axum::extract::{ConnectInfo, FromRequestParts, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};

use crate::protocol::*;
use crate::seal::OpenedHttp;
use crate::state::AppState;

pub struct MaybeIp(pub String);

#[async_trait]
impl<S> FromRequestParts<S> for MaybeIp
where
    S: Send + Sync,
{
    type Rejection = Infallible;

    async fn from_request_parts(
        parts: &mut axum::http::request::Parts,
        _state: &S,
    ) -> Result<Self, Infallible> {
        let ip = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip().to_string())
            .unwrap_or_else(|| "unknown".into());
        Ok(MaybeIp(ip))
    }
}

pub async fn reject_plain() -> impl IntoResponse {
    (
        StatusCode::UPGRADE_REQUIRED,
        "需要加密通道（syncnotes-seal-v1），明文已拒绝",
    )
}

pub async fn handle(State(state): State<AppState>, MaybeIp(ip): MaybeIp, body: Bytes) -> Response {
    if body.len() > 1024 * 1024 {
        return (StatusCode::PAYLOAD_TOO_LARGE, "加密请求过大").into_response();
    }
    let opened = match OpenedHttp::open(&state.seal, &body) {
        Ok(v) => v,
        Err(()) => {
            return (StatusCode::BAD_REQUEST, "加密通道无效").into_response();
        }
    };
    let (status, bytes) = dispatch(&state, &ip, &opened).await;
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/octet-stream")],
        opened.seal_response(status, &bytes),
    )
        .into_response()
}

fn headers_of(raw: &[u8]) -> HeaderMap {
    let mut h = HeaderMap::new();
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(raw) else {
        return h;
    };
    if let Some(a) = v.get("authorization").and_then(|x| x.as_str()) {
        if let Ok(val) = a.parse() {
            h.insert(header::AUTHORIZATION, val);
        }
    }
    h
}

fn peer(ip: &str) -> Option<ConnectInfo<SocketAddr>> {
    let addr = ip
        .parse::<IpAddr>()
        .ok()
        .map(|ip| SocketAddr::new(ip, 0))
        .or_else(|| "0.0.0.0:0".parse().ok());
    addr.map(ConnectInfo)
}

async fn dispatch(state: &AppState, ip: &str, req: &OpenedHttp) -> (u16, Vec<u8>) {
    let headers = headers_of(&req.headers_json);
    let path = req.path.split('?').next().unwrap_or(req.path.as_str());
    let result: Result<(u16, Vec<u8>), (StatusCode, String)> = match (req.method, path) {
        (1, "/api/register") => {
            let parsed: RegisterRequest = match serde_json::from_slice(&req.body) {
                Ok(v) => v,
                Err(_) => return (400, "请求格式错误".into()),
            };
            match crate::sync::register(State(state.clone()), axum::Json(parsed)).await {
                Ok(axum::Json(v)) => Ok((200, serde_json::to_vec(&v).unwrap_or_default())),
                Err(e) => Err(e),
            }
        }
        (1, "/api/login") => {
            let parsed: LoginRequest = match serde_json::from_slice(&req.body) {
                Ok(v) => v,
                Err(_) => return (400, "请求格式错误".into()),
            };
            match crate::sync::login(State(state.clone()), axum::Json(parsed)).await {
                Ok(axum::Json(v)) => Ok((200, serde_json::to_vec(&v).unwrap_or_default())),
                Err(e) => Err(e),
            }
        }
        (1, "/api/logout") => match crate::sync::logout(State(state.clone()), headers).await {
            Ok(code) => Ok((code.as_u16(), Vec::new())),
            Err(e) => Err(e),
        },
        (1, "/api/recover") => {
            let parsed: RecoverRequest = match serde_json::from_slice(&req.body) {
                Ok(v) => v,
                Err(_) => return (400, "请求格式错误".into()),
            };
            match crate::recovery::recover(State(state.clone()), peer(ip), axum::Json(parsed)).await
            {
                Ok(axum::Json(v)) => Ok((200, serde_json::to_vec(&v).unwrap_or_default())),
                Err(e) => Err(e),
            }
        }
        (1, "/api/recovery-code") => {
            let parsed: RecoveryCodeRequest = match serde_json::from_slice(&req.body) {
                Ok(v) => v,
                Err(_) => return (400, "请求格式错误".into()),
            };
            match crate::recovery::regenerate(State(state.clone()), headers, axum::Json(parsed))
                .await
            {
                Ok(axum::Json(v)) => Ok((200, serde_json::to_vec(&v).unwrap_or_default())),
                Err(e) => Err(e),
            }
        }
        (1, "/api/change-password") => {
            let parsed: ChangePasswordRequest = match serde_json::from_slice(&req.body) {
                Ok(v) => v,
                Err(_) => return (400, "请求格式错误".into()),
            };
            match crate::recovery::change_password(
                State(state.clone()),
                headers,
                axum::Json(parsed),
            )
            .await
            {
                Ok(code) => Ok((code.as_u16(), Vec::new())),
                Err(e) => Err(e),
            }
        }
        _ => Err((StatusCode::NOT_FOUND, "未知接口".into())),
    };
    match result {
        Ok(v) => v,
        Err((code, msg)) => (code.as_u16(), msg.into_bytes()),
    }
}
