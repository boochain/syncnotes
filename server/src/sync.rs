//! WebSocket handler + HTTP auth routes.

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;

use crate::auth::{hash_password, validate_username, verify_password};
use crate::protocol::*;
use crate::state::{AppState, Conn};
use crate::storage::UpsertOutcome;

pub async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        protocol: PROTOCOL_VERSION,
        features: vec!["trash".into(), "seal".into()],
        trash_retention_days: state.trash_days,
        seal_pub: state.seal.public_b64(),
    })
}

pub async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !state.allow_register {
        return Err((StatusCode::FORBIDDEN, "注册已关闭".into()));
    }
    validate_username(&req.username).map_err(|e| (StatusCode::BAD_REQUEST, e.into()))?;
    crate::auth::validate_password(&req.password)
        .map_err(|e| (StatusCode::BAD_REQUEST, e.into()))?;
    if state
        .storage
        .find_user(&req.username)
        .map_err(internal)?
        .is_some()
    {
        return Err((StatusCode::CONFLICT, "用户名已存在".into()));
    }
    let hash = hash_password(&req.password);
    let user = state
        .storage
        .create_user(&req.username, &hash)
        .map_err(internal)?;
    // One-time recovery code (shown once by the client; only its argon2 hash is stored).
    let code = crate::auth::generate_recovery_code();
    state
        .storage
        .set_recovery_hash(&user.id, Some(&crate::auth::hash_recovery_code(&code)))
        .map_err(internal)?;
    // Token for register is issued with a placeholder device; client should login properly.
    let token = state
        .storage
        .create_token(&user.id, "register", Some("register"))
        .map_err(internal)?;
    Ok(Json(AuthResponse {
        token,
        user_id: user.id,
        username: user.username,
        recovery_code: Some(code),
        has_recovery_code: true,
        must_change_password: false,
    }))
}

pub async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let user = state
        .storage
        .find_user(&req.username)
        .map_err(internal)?
        .ok_or((StatusCode::UNAUTHORIZED, "用户名或密码错误".into()))?;
    if !verify_password(&req.password, &user.password_hash) {
        return Err((StatusCode::UNAUTHORIZED, "用户名或密码错误".into()));
    }
    if req.device_id.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "缺少 device_id".into()));
    }
    let token = state
        .storage
        .create_token(&user.id, &req.device_id, req.device_name.as_deref())
        .map_err(internal)?;
    Ok(Json(AuthResponse {
        token,
        user_id: user.id,
        username: user.username,
        recovery_code: None,
        has_recovery_code: user.recovery_hash.is_some(),
        must_change_password: user.must_change_password,
    }))
}

/// Revoke the bearer token (client logout).
pub async fn logout(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
) -> Result<StatusCode, (StatusCode, String)> {
    let token = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or((StatusCode::UNAUTHORIZED, "缺少令牌".to_string()))?;
    state.storage.revoke_token(token).map_err(internal)?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) fn internal(e: impl std::fmt::Display) -> (StatusCode, String) {
    tracing::error!("storage error: {e}");
    (StatusCode::INTERNAL_SERVER_ERROR, "服务器内部错误".into())
}

pub async fn ws_handler(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    // Handshake before any application byte. A plaintext frame is dropped;
    // we never echo it.
    let hello = tokio::time::timeout(std::time::Duration::from_secs(15), stream.next()).await;
    let client_frame = match hello {
        Ok(Some(Ok(Message::Binary(b)))) => b,
        _ => return,
    };
    let (server_hello, mut pair) = match crate::seal::accept_client_hello(&state.seal, &client_frame)
    {
        Ok(v) => v,
        Err(()) => return,
    };
    if sink.send(Message::Binary(server_hello)).await.is_err() {
        return;
    }
    let (tx, mut rx) = mpsc::unbounded_channel::<ServerMessage>();

    // Writer task — every outbound frame is sealed with this socket's key.
    let mut send_dir = pair.send;
    let writer = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            let Ok(text) = serde_json::to_vec(&msg) else {
                continue;
            };
            let frame = send_dir.seal(&text);
            if sink.send(Message::Binary(frame)).await.is_err() {
                break;
            }
        }
        let _ = sink.send(Message::Close(None)).await;
    });

    let mut conn_id: Option<u64> = None;
    let mut authed: Option<(String, String, String)> = None; // user_id, username, device_id
    let mut auth_token: Option<String> = None;
    let kill = std::sync::Arc::new(tokio::sync::Notify::new());
    // Tokens can also be revoked by `syncnotes-server admin reset-password` from another process.
    let mut recheck = tokio::time::interval(std::time::Duration::from_secs(15));
    recheck.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        let msg = tokio::select! {
            m = stream.next() => match m {
                Some(Ok(m)) => m,
                _ => break,
            },
            _ = kill.notified() => break,
            _ = recheck.tick() => {
                if let Some(t) = &auth_token {
                    if !matches!(state.storage.validate_token(t), Ok(Some(_))) {
                        let _ = tx.send(ServerMessage::AuthError {
                            message: "登录已失效，请重新登录".into(),
                        });
                        break;
                    }
                }
                continue;
            }
        };
        // Kicked by password reset/recovery in this process.
        if let Some(cid) = conn_id {
            if !state.has_conn(cid) {
                break;
            }
        }
        let text = match msg {
            Message::Binary(b) => match pair.recv.open(&b) {
                Ok(p) => String::from_utf8(p).unwrap_or_default(),
                Err(()) => {
                    let _ = tx.send(ServerMessage::Error {
                        message: "无法解密".into(),
                    });
                    continue;
                }
            },
            Message::Text(_) => {
                let _ = tx.send(ServerMessage::Error {
                    message: "拒绝明文帧".into(),
                });
                continue;
            }
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) => continue,
        };
        let client: ClientMessage = match serde_json::from_str(&text) {
            Ok(m) => m,
            Err(e) => {
                let _ = tx.send(ServerMessage::Error {
                    message: format!("协议错误: {e}"),
                });
                continue;
            }
        };

        match client {
            ClientMessage::Auth { token, device_id } => {
                let must_change = match state.storage.validate_token(&token) {
                    Ok(Some((ref uid, _))) => state
                        .storage
                        .find_user_by_id(uid)
                        .ok()
                        .flatten()
                        .map(|u| u.must_change_password)
                        .unwrap_or(false),
                    _ => false,
                };
                if must_change {
                    let _ = tx.send(ServerMessage::AuthError {
                        message: "请先修改临时密码".into(),
                    });
                    continue;
                }
                match state.storage.validate_token(&token) {
                    Ok(Some((uid, uname))) => {
                        auth_token = Some(token.clone());
                        if let Some(cid) = conn_id {
                            state.remove_conn(cid);
                        }
                        let id = state.register_conn(Conn {
                            user_id: uid.clone(),
                            device_id: device_id.clone(),
                            tx: tx.clone(),
                            kill: kill.clone(),
                        });
                        conn_id = Some(id);
                        authed = Some((uid.clone(), uname.clone(), device_id));
                        let _ = tx.send(ServerMessage::AuthOk {
                            user_id: uid,
                            username: uname,
                        });
                    }
                    Ok(None) => {
                        let _ = tx.send(ServerMessage::AuthError {
                            message: "无效令牌".into(),
                        });
                    }
                    Err(e) => {
                        let _ = tx.send(ServerMessage::Error {
                            message: format!("认证失败: {e}"),
                        });
                    }
                }
            }
            ClientMessage::Ping => {
                let _ = tx.send(ServerMessage::Pong);
            }
            other => {
                let Some((ref user_id, _, ref device_id)) = authed else {
                    let _ = tx.send(ServerMessage::AuthError {
                        message: "请先认证".into(),
                    });
                    continue;
                };
                handle_authed(&state, user_id, device_id, other, &tx);
            }
        }
    }

    if let Some(cid) = conn_id {
        state.remove_conn(cid);
    }
    drop(tx);
    let _ = writer.await;
}

fn handle_authed(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    msg: ClientMessage,
    tx: &mpsc::UnboundedSender<ServerMessage>,
) {
    match msg {
        ClientMessage::UpsertBlock {
            id,
            kind,
            title,
            payload,
            parent_id,
            viewed_mode,
            client_updated_at,
            deleted,
            deleted_at,
        } => {
            if !crate::blocks::valid_kind(&kind) {
                let _ = tx.send(ServerMessage::Error {
                    message: format!("非法块类型: {kind}"),
                });
                return;
            }
            if id.is_empty() || id.len() > 64 {
                let _ = tx.send(ServerMessage::Error {
                    message: "非法块 id".into(),
                });
                return;
            }
            match state.storage.upsert_block(
                user_id,
                device_id,
                &id,
                &kind,
                &title,
                &payload,
                parent_id.as_deref(),
                viewed_mode,
                client_updated_at,
                deleted,
                deleted_at,
            ) {
                Ok(UpsertOutcome::Applied(block)) => {
                    let purged = block.deleted;
                    let root = block.id.clone();
                    state.broadcast_user(user_id, &ServerMessage::BlockUpdate { block });
                    if purged {
                        // Permanent delete: cascade to descendants + remove file blobs.
                        crate::trash::purge_tree(state, user_id, &root);
                    }
                }
                Ok(UpsertOutcome::Stale(block)) => {
                    // Tell this client the current winner.
                    let _ = tx.send(ServerMessage::BlockUpdate { block });
                }
                Err(e) => {
                    let _ = tx.send(ServerMessage::Error {
                        message: format!("保存失败: {e}"),
                    });
                }
            }
        }
        ClientMessage::SetViewed { block_id, viewed } => {
            match state
                .storage
                .set_viewed(user_id, device_id, &block_id, viewed)
            {
                Ok(Some((_block, device_scope, seq))) => {
                    let msg = ServerMessage::ViewedUpdate {
                        block_id,
                        viewed,
                        device_id: device_scope.clone(),
                        seq,
                    };
                    match device_scope {
                        Some(dev) => state.broadcast_device(user_id, &dev, &msg),
                        None => state.broadcast_user(user_id, &msg),
                    }
                }
                Ok(None) => {
                    let _ = tx.send(ServerMessage::Error {
                        message: "块不存在".into(),
                    });
                }
                Err(e) => {
                    let _ = tx.send(ServerMessage::Error {
                        message: format!("标记已读失败: {e}"),
                    });
                }
            }
        }
        ClientMessage::SyncSince { since_seq } => {
            match (
                state.storage.blocks_since(user_id, since_seq),
                state
                    .storage
                    .device_views_since(user_id, device_id, since_seq),
                state.storage.latest_seq(user_id),
            ) {
                (Ok(blocks), Ok(views), Ok(latest)) => {
                    for block in blocks {
                        // For global-viewed blocks, the BlockUpdate already carries viewed_global.
                        let _ = tx.send(ServerMessage::BlockUpdate { block });
                    }
                    for (block_id, viewed, seq) in views {
                        let _ = tx.send(ServerMessage::ViewedUpdate {
                            block_id,
                            viewed,
                            device_id: Some(device_id.to_string()),
                            seq,
                        });
                    }
                    let _ = tx.send(ServerMessage::SyncComplete { latest_seq: latest });
                }
                (e1, e2, e3) => {
                    let err = e1.err().or(e2.err()).or(e3.err()).unwrap();
                    let _ = tx.send(ServerMessage::Error {
                        message: format!("同步失败: {err}"),
                    });
                }
            }
        }
        ClientMessage::Auth { .. } | ClientMessage::Ping => unreachable!(),
    }
}
