//! WebSocket / HTTP wire protocol.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::blocks::{Block, ViewedMode};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
    pub device_id: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthResponse {
    pub token: String,
    pub user_id: String,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// Authenticate an already-open WebSocket with a token.
    Auth {
        token: String,
        device_id: String,
    },
    /// Create or update a block (idempotent by id; client may reuse ids for offline creates).
    UpsertBlock {
        id: String,
        kind: String,
        title: String,
        payload: Value,
        parent_id: Option<String>,
        viewed_mode: ViewedMode,
        /// Client-side updated_at for LWW conflict resolution.
        client_updated_at: i64,
        deleted: bool,
    },
    /// Mark a block viewed (honours the block's viewed_mode).
    SetViewed {
        block_id: String,
        viewed: bool,
    },
    /// Ask server to send all blocks with seq > since_seq (offline catch-up).
    SyncSince {
        since_seq: i64,
    },
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    AuthOk {
        user_id: String,
        username: String,
    },
    AuthError {
        message: String,
    },
    /// Full block snapshot (create / update / delete / catch-up).
    BlockUpdate {
        block: Block,
    },
    /// Device-scoped or global viewed state change.
    ViewedUpdate {
        block_id: String,
        viewed: bool,
        /// If Some, this is a per-device update for that device; if None, global.
        device_id: Option<String>,
        seq: i64,
    },
    SyncComplete {
        latest_seq: i64,
    },
    Error {
        message: String,
    },
    Pong,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResponse {
    pub status: String,
    pub version: String,
}
