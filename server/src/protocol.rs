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
    /// Plain one-time recovery code; only present right after it was generated (show once).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery_code: Option<String>,
    /// False for legacy accounts that never generated a code (client prompts once).
    #[serde(default)]
    pub has_recovery_code: bool,
    /// Admin reset with a temporary password: client must force a password change.
    #[serde(default)]
    pub must_change_password: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoverRequest {
    pub username: String,
    pub recovery_code: String,
    pub new_password: String,
    pub device_id: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryCodeRequest {
    /// Current password (re-authentication; a stolen token alone can't rotate the code).
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryCodeResponse {
    pub recovery_code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangePasswordRequest {
    pub old_password: String,
    pub new_password: String,
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
        /// Recycle-bin timestamp. Absent (old clients) = keep server value;
        /// `null` = restore from bin; number = move to bin.
        #[serde(default, deserialize_with = "double_option")]
        deleted_at: Option<Option<i64>>,
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
    /// Wire protocol revision. 3 = application-layer seal (syncnotes-seal-v1) + recycle bin.
    #[serde(default)]
    pub protocol: u32,
    #[serde(default)]
    pub features: Vec<String>,
    /// Recycle-bin retention in days (0 = never purge).
    #[serde(default)]
    pub trash_retention_days: u32,
    /// X25519 static public key, standard base64. Not a secret.
    #[serde(default)]
    pub seal_pub: String,
}

pub const PROTOCOL_VERSION: u32 = 3;

/// Distinguish a missing field (None) from an explicit null (Some(None)).
fn double_option<'de, D>(d: D) -> Result<Option<Option<i64>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<i64>::deserialize(d).map(Some)
}
