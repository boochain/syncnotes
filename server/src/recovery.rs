//! 忘记密码：一次性恢复码 (recovery code) + 修改密码。
//!
//! Only `users.password_hash`, `users.recovery_hash`, `users.must_change_password` and the
//! `tokens` table are ever modified here. Blocks, files, recycle bin and read state are keyed by
//! the immutable user id and are not encrypted with the password, so all data survives a reset.

use std::net::SocketAddr;

use axum::{
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    Json,
};

use crate::auth::{
    dummy_verify, generate_recovery_code, hash_password, hash_recovery_code, validate_password,
    verify_password, verify_recovery_code,
};
use crate::protocol::*;
use crate::state::AppState;
use crate::sync::internal;

type ApiErr = (StatusCode, String);

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

fn authed_user(state: &AppState, headers: &HeaderMap) -> Result<crate::storage::UserRow, ApiErr> {
    let t = bearer(headers).ok_or((StatusCode::UNAUTHORIZED, "缺少令牌".to_string()))?;
    let (uid, _) = state
        .storage
        .validate_token(t)
        .map_err(internal)?
        .ok_or((StatusCode::UNAUTHORIZED, "无效令牌".to_string()))?;
    state
        .storage
        .find_user_by_id(&uid)
        .map_err(internal)?
        .ok_or((StatusCode::UNAUTHORIZED, "无效令牌".to_string()))
}

const RECOVER_FAIL: &str = "用户名或恢复码错误";

/// POST /api/recover — username + recovery code + new password.
/// Resets the password, revokes every token, consumes the code and issues a new one.
pub async fn recover(
    State(state): State<AppState>,
    peer: Option<ConnectInfo<SocketAddr>>,
    Json(req): Json<RecoverRequest>,
) -> Result<Json<AuthResponse>, ApiErr> {
    let ip = peer
        .map(|c| c.0.ip().to_string())
        .unwrap_or_else(|| "unknown".into());
    let uname = req.username.trim().to_string();
    let lim = &state.recovery_limiter;
    if lim.blocked(&uname, &ip) {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "尝试次数过多，请 15 分钟后再试".into(),
        ));
    }
    validate_password(&req.new_password).map_err(|e| (StatusCode::BAD_REQUEST, e.into()))?;
    if req.device_id.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, "缺少 device_id".into()));
    }
    let user = state.storage.find_user(&uname).map_err(internal)?;
    let ok = match &user {
        Some(u) => match &u.recovery_hash {
            Some(h) => verify_recovery_code(&req.recovery_code, h),
            None => {
                dummy_verify(&req.recovery_code);
                false
            }
        },
        None => {
            dummy_verify(&req.recovery_code);
            false
        }
    };
    let Some(user) = user.filter(|_| ok) else {
        lim.fail(&uname, &ip);
        tracing::warn!("恢复码校验失败 user={uname} ip={ip}");
        return Err((StatusCode::UNAUTHORIZED, RECOVER_FAIL.into()));
    };
    let new_code = generate_recovery_code();
    let consumed = state
        .storage
        .recover_account(
            &user.id,
            user.recovery_hash.as_deref().unwrap_or_default(),
            &hash_password(&req.new_password),
            &hash_recovery_code(&new_code),
        )
        .map_err(internal)?;
    if !consumed {
        // Lost a race with another request using the same code: one-time means one-time.
        lim.fail(&uname, &ip);
        return Err((StatusCode::UNAUTHORIZED, RECOVER_FAIL.into()));
    }
    lim.reset_user(&uname);
    state.kick_user(&user.id);
    tracing::info!("用户 {uname} 通过恢复码重置了密码（所有旧会话已失效）");
    let token = state
        .storage
        .create_token(&user.id, &req.device_id, req.device_name.as_deref())
        .map_err(internal)?;
    Ok(Json(AuthResponse {
        token,
        user_id: user.id,
        username: user.username,
        recovery_code: Some(new_code),
        has_recovery_code: true,
        must_change_password: false,
    }))
}

/// POST /api/recovery-code — (re)generate the recovery code. Bearer token + current password.
pub async fn regenerate(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RecoveryCodeRequest>,
) -> Result<Json<RecoveryCodeResponse>, ApiErr> {
    let user = authed_user(&state, &headers)?;
    let lim = &state.recovery_limiter;
    if lim.blocked(&user.username, "token") {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "尝试次数过多，请 15 分钟后再试".into(),
        ));
    }
    if !verify_password(&req.password, &user.password_hash) {
        lim.fail(&user.username, "token");
        return Err((StatusCode::UNAUTHORIZED, "当前密码错误".into()));
    }
    let code = generate_recovery_code();
    state
        .storage
        .set_recovery_hash(&user.id, Some(&hash_recovery_code(&code)))
        .map_err(internal)?;
    Ok(Json(RecoveryCodeResponse {
        recovery_code: code,
    }))
}

/// POST /api/change-password — also used for the forced change after an admin reset.
/// Keeps the caller's token, revokes all other sessions, clears `must_change_password`.
pub async fn change_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<ChangePasswordRequest>,
) -> Result<StatusCode, ApiErr> {
    let user = authed_user(&state, &headers)?;
    let lim = &state.recovery_limiter;
    if lim.blocked(&user.username, "token") {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "尝试次数过多，请 15 分钟后再试".into(),
        ));
    }
    if !verify_password(&req.old_password, &user.password_hash) {
        lim.fail(&user.username, "token");
        return Err((StatusCode::UNAUTHORIZED, "当前密码错误".into()));
    }
    validate_password(&req.new_password).map_err(|e| (StatusCode::BAD_REQUEST, e.into()))?;
    if req.new_password == req.old_password {
        return Err((StatusCode::BAD_REQUEST, "新密码不能与旧密码相同".into()));
    }
    let keep = bearer(&headers).map(str::to_string);
    state
        .storage
        .set_password(
            &user.id,
            &hash_password(&req.new_password),
            false,
            keep.as_deref(),
        )
        .map_err(internal)?;
    // Other devices' live sockets are dropped by the periodic token re-check.
    Ok(StatusCode::NO_CONTENT)
}
