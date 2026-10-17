//! Extensible block type system.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Supported block kinds. New kinds can be added without breaking clients
/// that treat unknown kinds as opaque JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockKind {
    Message,
    Note,
    File,
    Folder,
    #[serde(other)]
    Unknown,
}

impl BlockKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            BlockKind::Message => "message",
            BlockKind::Note => "note",
            BlockKind::File => "file",
            BlockKind::Folder => "folder",
            BlockKind::Unknown => "unknown",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s {
            "message" => BlockKind::Message,
            "note" => BlockKind::Note,
            "file" => BlockKind::File,
            "folder" => BlockKind::Folder,
            _ => BlockKind::Unknown,
        }
    }
}

/// How viewed/seen state is tracked for a block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ViewedMode {
    /// Each device tracks seen/unseen independently.
    #[default]
    PerDevice,
    /// Seen on one device = seen everywhere.
    Global,
}

impl ViewedMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            ViewedMode::PerDevice => "per_device",
            ViewedMode::Global => "global",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s {
            "global" => ViewedMode::Global,
            _ => ViewedMode::PerDevice,
        }
    }
}

/// A syncable content block.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub id: String,
    /// Raw kind string ("message", "note", "file", "folder", or a future type).
    /// Stored verbatim so newer clients' types survive a round-trip through this server.
    pub kind: String,
    pub title: String,
    /// Type-specific payload (message text, markdown, file meta, children ids…).
    pub payload: Value,
    /// Parent folder id, if any.
    pub parent_id: Option<String>,
    pub viewed_mode: ViewedMode,
    /// Global viewed flag (only meaningful when viewed_mode == Global).
    pub viewed_global: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub created_by: String,
    /// Permanently deleted tombstone (purged from the recycle bin).
    pub deleted: bool,
    /// Soft delete: when set, the block is in the recycle bin (回收站).
    /// Descendants of a trashed folder stay untouched and are hidden/restored with it.
    #[serde(default)]
    pub deleted_at: Option<i64>,
    /// Device that moved the block to the recycle bin.
    #[serde(default)]
    pub deleted_by: Option<String>,
    /// Monotonic server sequence for ordering / offline replay.
    pub seq: i64,
}

/// Device-local viewed marker.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceView {
    pub block_id: String,
    pub device_id: String,
    pub viewed: bool,
    pub updated_at: i64,
}

/// Valid kind strings: 1-32 chars of [a-z0-9_].
pub fn valid_kind(k: &str) -> bool {
    !k.is_empty()
        && k.len() <= 32
        && k.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn kind_validation() {
        assert!(valid_kind("note"));
        assert!(valid_kind("check_list2"));
        assert!(!valid_kind(""));
        assert!(!valid_kind("Note"));
        assert!(!valid_kind("a b"));
        assert!(!valid_kind(&"x".repeat(33)));
        assert_eq!(BlockKind::from_str_loose("folder"), BlockKind::Folder);
    }
}
