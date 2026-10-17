//! Recycle bin (回收站): permanent deletion cascade, blob cleanup, retention purge.

use crate::blocks::Block;
use crate::protocol::ServerMessage;
use crate::state::AppState;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn remove_blob(state: &AppState, user_id: &str, b: &Block) {
    if b.kind != "file" {
        return;
    }
    let Some(fid) = b.payload.get("file_id").and_then(|v| v.as_str()) else {
        return;
    };
    if fid.is_empty() || !fid.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return;
    }
    let _ = std::fs::remove_file(state.files_dir.join(user_id).join(fid));
}

/// Tombstone `root` + descendants, broadcast changes, delete file blobs.
pub fn purge_tree(state: &AppState, user_id: &str, root: &str) -> usize {
    match state.storage.purge_tree(user_id, root) {
        Ok(blocks) => {
            let n = blocks.len();
            for b in blocks {
                remove_blob(state, user_id, &b);
                state.broadcast_user(user_id, &ServerMessage::BlockUpdate { block: b });
            }
            n
        }
        Err(e) => {
            tracing::error!("purge failed: {e}");
            0
        }
    }
}

/// Purge recycle-bin entries older than `days` (0 = never). Returns purged root count.
pub fn purge_expired(state: &AppState, days: u32, now_ms: i64) -> usize {
    if days == 0 {
        return 0;
    }
    let cutoff = now_ms - days as i64 * DAY_MS;
    let Ok(list) = state.storage.expired_trash(cutoff) else {
        return 0;
    };
    for (uid, id) in &list {
        purge_tree(state, uid, id);
    }
    list.len()
}
