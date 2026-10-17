//! SQLite persistence.

use std::path::Path;
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};

use crate::blocks::{Block, ViewedMode};

#[derive(Clone)]
pub struct Storage {
    conn: Arc<Mutex<Connection>>,
}

#[derive(Debug, Clone)]
pub struct UserRow {
    pub id: String,
    pub username: String,
    pub password_hash: String,
    /// Argon2 hash of the current one-time recovery code (None = never generated).
    pub recovery_hash: Option<String>,
    /// Set by admin reset: the user must choose a new password after next login.
    pub must_change_password: bool,
}

/// Summary row for `admin list-users`.
#[derive(Debug, Clone)]
pub struct UserSummary {
    pub id: String,
    pub username: String,
    pub created_at: i64,
    pub blocks: i64,
    pub trashed: i64,
    pub tokens: i64,
    pub has_recovery_code: bool,
    pub must_change_password: bool,
}

/// Result of applying an upsert.
#[derive(Debug)]
pub enum UpsertOutcome {
    Applied(Block),
    /// Incoming change was older than stored (LWW); returns current block.
    Stale(Block),
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    device_name TEXT,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blocks (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    payload TEXT NOT NULL,
    parent_id TEXT,
    viewed_mode TEXT NOT NULL,
    viewed_global INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    created_by TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER,
    deleted_by TEXT,
    seq INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
);
CREATE INDEX IF NOT EXISTS idx_blocks_seq ON blocks(user_id, seq);
CREATE TABLE IF NOT EXISTS device_views (
    user_id TEXT NOT NULL,
    block_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    viewed INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (user_id, block_id, device_id)
);
CREATE TABLE IF NOT EXISTS counters (
    user_id TEXT PRIMARY KEY,
    seq INTEGER NOT NULL
);
"#;

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn row_to_block(r: &rusqlite::Row) -> rusqlite::Result<Block> {
    let payload: String = r.get("payload")?;
    let vm: String = r.get("viewed_mode")?;
    Ok(Block {
        id: r.get("id")?,
        kind: r.get("kind")?,
        title: r.get("title")?,
        payload: serde_json::from_str(&payload).unwrap_or(serde_json::Value::Null),
        parent_id: r.get("parent_id")?,
        viewed_mode: ViewedMode::from_str_loose(&vm),
        viewed_global: r.get::<_, i64>("viewed_global")? != 0,
        created_at: r.get("created_at")?,
        updated_at: r.get("updated_at")?,
        created_by: r.get("created_by")?,
        deleted: r.get::<_, i64>("deleted")? != 0,
        deleted_at: r.get("deleted_at")?,
        deleted_by: r.get("deleted_by")?,
        seq: r.get("seq")?,
    })
}

impl Storage {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        Self::init(conn)
    }

    pub fn in_memory() -> rusqlite::Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> rusqlite::Result<Self> {
        conn.execute_batch(SCHEMA)?;
        Self::migrate(&conn)?;
        // Let admin CLI and the running server share the WAL database without SQLITE_BUSY.
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    /// Backward-compatible migration: add recycle-bin columns to pre-trash databases.
    fn migrate(conn: &Connection) -> rusqlite::Result<()> {
        let cols: Vec<String> = conn
            .prepare("PRAGMA table_info(blocks)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        for (name, ty) in [("deleted_at", "INTEGER"), ("deleted_by", "TEXT")] {
            if !cols.iter().any(|c| c == name) {
                conn.execute_batch(&format!("ALTER TABLE blocks ADD COLUMN {name} {ty}"))?;
            }
        }
        // Password recovery columns (v0.5). Never touches ids, so all data stays owned by the user.
        let ucols: Vec<String> = conn
            .prepare("PRAGMA table_info(users)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<rusqlite::Result<_>>()?;
        for (name, ty) in [
            ("recovery_hash", "TEXT"),
            ("must_change_password", "INTEGER NOT NULL DEFAULT 0"),
        ] {
            if !ucols.iter().any(|c| c == name) {
                conn.execute_batch(&format!("ALTER TABLE users ADD COLUMN {name} {ty}"))?;
            }
        }
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_blocks_trash ON blocks(deleted_at) WHERE deleted_at IS NOT NULL AND deleted = 0",
        )?;
        Ok(())
    }

    fn next_seq(conn: &Connection, user_id: &str) -> rusqlite::Result<i64> {
        conn.execute(
            "INSERT INTO counters(user_id, seq) VALUES (?1, 1)
             ON CONFLICT(user_id) DO UPDATE SET seq = seq + 1",
            params![user_id],
        )?;
        conn.query_row(
            "SELECT seq FROM counters WHERE user_id = ?1",
            params![user_id],
            |r| r.get(0),
        )
    }

    // ---------- users / tokens ----------

    pub fn create_user(&self, username: &str, password_hash: &str) -> rusqlite::Result<UserRow> {
        let id = uuid::Uuid::new_v4().to_string();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO users(id, username, password_hash, created_at) VALUES (?1, ?2, ?3, ?4)",
            params![id, username, password_hash, now_ms()],
        )?;
        Ok(UserRow {
            id,
            username: username.into(),
            password_hash: password_hash.into(),
            recovery_hash: None,
            must_change_password: false,
        })
    }

    fn row_to_user(r: &rusqlite::Row) -> rusqlite::Result<UserRow> {
        Ok(UserRow {
            id: r.get(0)?,
            username: r.get(1)?,
            password_hash: r.get(2)?,
            recovery_hash: r.get(3)?,
            must_change_password: r.get::<_, i64>(4)? != 0,
        })
    }

    pub fn find_user(&self, username: &str) -> rusqlite::Result<Option<UserRow>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, username, password_hash, recovery_hash, must_change_password FROM users WHERE username = ?1",
            params![username],
            Self::row_to_user,
        )
        .optional()
    }

    pub fn find_user_by_id(&self, user_id: &str) -> rusqlite::Result<Option<UserRow>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, username, password_hash, recovery_hash, must_change_password FROM users WHERE id = ?1",
            params![user_id],
            Self::row_to_user,
        )
        .optional()
    }

    /// Replace the password hash and revoke every token of the user (all devices logged out),
    /// optionally keeping one token (the caller's current session). Only `users.password_hash`,
    /// `users.must_change_password` and `tokens` are touched: the user id, blocks, files,
    /// recycle bin and read state are untouched, so every old note stays accessible.
    pub fn set_password(
        &self,
        user_id: &str,
        password_hash: &str,
        must_change: bool,
        keep_token: Option<&str>,
    ) -> rusqlite::Result<usize> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let n = tx.execute(
            "UPDATE users SET password_hash = ?1, must_change_password = ?2 WHERE id = ?3",
            params![password_hash, must_change as i64, user_id],
        )?;
        if n == 1 {
            tx.execute(
                "DELETE FROM tokens WHERE user_id = ?1 AND token IS NOT ?2",
                params![user_id, keep_token],
            )?;
        }
        tx.commit()?;
        Ok(n)
    }

    pub fn set_recovery_hash(&self, user_id: &str, hash: Option<&str>) -> rusqlite::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE users SET recovery_hash = ?1 WHERE id = ?2",
            params![hash, user_id],
        )?;
        Ok(())
    }

    /// Atomically consume a recovery code: only succeeds if the stored hash is still `expected`
    /// (prevents two concurrent requests from both using the same one-time code).
    #[allow(clippy::too_many_arguments)]
    pub fn recover_account(
        &self,
        user_id: &str,
        expected_recovery_hash: &str,
        new_password_hash: &str,
        new_recovery_hash: &str,
    ) -> rusqlite::Result<bool> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let n = tx.execute(
            "UPDATE users SET password_hash = ?1, recovery_hash = ?2, must_change_password = 0
             WHERE id = ?3 AND recovery_hash = ?4",
            params![new_password_hash, new_recovery_hash, user_id, expected_recovery_hash],
        )?;
        if n == 1 {
            tx.execute("DELETE FROM tokens WHERE user_id = ?1", params![user_id])?;
        }
        tx.commit()?;
        Ok(n == 1)
    }

    pub fn token_count(&self, user_id: &str) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM tokens WHERE user_id = ?1",
            params![user_id],
            |r| r.get(0),
        )
    }

    pub fn list_users(&self) -> rusqlite::Result<Vec<UserSummary>> {
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare(
            "SELECT u.id, u.username, u.created_at,
                    (SELECT COUNT(*) FROM blocks b WHERE b.user_id = u.id AND b.deleted = 0),
                    (SELECT COUNT(*) FROM blocks b WHERE b.user_id = u.id AND b.deleted = 0 AND b.deleted_at IS NOT NULL),
                    (SELECT COUNT(*) FROM tokens t WHERE t.user_id = u.id),
                    u.recovery_hash IS NOT NULL, u.must_change_password
             FROM users u ORDER BY u.username",
        )?;
        let rows = st.query_map([], |r| {
            Ok(UserSummary {
                id: r.get(0)?,
                username: r.get(1)?,
                created_at: r.get(2)?,
                blocks: r.get(3)?,
                trashed: r.get(4)?,
                tokens: r.get(5)?,
                has_recovery_code: r.get::<_, i64>(6)? != 0,
                must_change_password: r.get::<_, i64>(7)? != 0,
            })
        })?;
        rows.collect()
    }

    /// Every block of a user (live, recycle bin and purged tombstones), ordered by seq.
    pub fn all_blocks(&self, user_id: &str) -> rusqlite::Result<Vec<Block>> {
        self.blocks_since(user_id, i64::MIN)
    }

    /// All per-device read states of a user: (block_id, device_id, viewed).
    pub fn all_device_views(&self, user_id: &str) -> rusqlite::Result<Vec<(String, String, bool)>> {
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare(
            "SELECT block_id, device_id, viewed FROM device_views WHERE user_id = ?1 ORDER BY block_id, device_id",
        )?;
        let rows = st.query_map(params![user_id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? != 0))
        })?;
        rows.collect()
    }

    /// Online-safe consistent copy of the whole database (works while the server runs, WAL).
    pub fn backup_to(&self, out: &Path) -> rusqlite::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("VACUUM INTO ?1", params![out.to_string_lossy()])?;
        Ok(())
    }

    pub fn create_token(
        &self,
        user_id: &str,
        device_id: &str,
        device_name: Option<&str>,
    ) -> rusqlite::Result<String> {
        let token = crate::auth::random_token();
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO tokens(token, user_id, device_id, device_name, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![token, user_id, device_id, device_name, now_ms()],
        )?;
        Ok(token)
    }

    /// Returns (user_id, username) for a valid token.
    pub fn validate_token(&self, token: &str) -> rusqlite::Result<Option<(String, String)>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT u.id, u.username FROM tokens t JOIN users u ON u.id = t.user_id WHERE t.token = ?1",
            params![token],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
    }

    pub fn revoke_token(&self, token: &str) -> rusqlite::Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM tokens WHERE token = ?1", params![token])?;
        Ok(())
    }

    // ---------- blocks ----------

    pub fn get_block(&self, user_id: &str, id: &str) -> rusqlite::Result<Option<Block>> {
        let conn = self.conn.lock().unwrap();
        Self::get_block_inner(&conn, user_id, id)
    }

    fn get_block_inner(
        conn: &Connection,
        user_id: &str,
        id: &str,
    ) -> rusqlite::Result<Option<Block>> {
        conn.query_row(
            "SELECT * FROM blocks WHERE user_id = ?1 AND id = ?2",
            params![user_id, id],
            row_to_block,
        )
        .optional()
    }

    /// Last-writer-wins upsert keyed on client_updated_at.
    #[allow(clippy::too_many_arguments)]
    pub fn upsert_block(
        &self,
        user_id: &str,
        device_id: &str,
        id: &str,
        kind: &str,
        title: &str,
        payload: &serde_json::Value,
        parent_id: Option<&str>,
        viewed_mode: ViewedMode,
        client_updated_at: i64,
        deleted: bool,
        deleted_at: Option<Option<i64>>,
    ) -> rusqlite::Result<UpsertOutcome> {
        let conn = self.conn.lock().unwrap();
        let existing = Self::get_block_inner(&conn, user_id, id)?;
        if let Some(ref b) = existing {
            if client_updated_at < b.updated_at {
                return Ok(UpsertOutcome::Stale(b.clone()));
            }
        }
        let seq = Self::next_seq(&conn, user_id)?;
        let payload_s = serde_json::to_string(payload).unwrap_or_else(|_| "null".into());
        let (created_at, created_by, viewed_global) = match &existing {
            Some(b) => (b.created_at, b.created_by.clone(), b.viewed_global),
            None => (client_updated_at, device_id.to_string(), false),
        };
        // Content edits reset global viewed flag (new content = unseen).
        let content_changed = existing
            .as_ref()
            .map(|b| b.title != title || &b.payload != payload)
            .unwrap_or(true);
        let viewed_global = if content_changed {
            false
        } else {
            viewed_global
        };
        let (deleted_at, deleted_by) = match (deleted_at, &existing) {
            // Old client (field absent): keep current recycle-bin state.
            (None, Some(b)) => (b.deleted_at, b.deleted_by.clone()),
            (None, None) | (Some(None), _) => (None, None),
            (Some(Some(t)), Some(b)) if b.deleted_at.is_some() => (Some(t), b.deleted_by.clone()),
            (Some(Some(t)), _) => (Some(t), Some(device_id.to_string())),
        };
        conn.execute(
            "INSERT INTO blocks(id, user_id, kind, title, payload, parent_id, viewed_mode, viewed_global,
                                created_at, updated_at, created_by, deleted, seq, deleted_at, deleted_by)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
             ON CONFLICT(user_id, id) DO UPDATE SET
               kind = excluded.kind, title = excluded.title, payload = excluded.payload,
               parent_id = excluded.parent_id, viewed_mode = excluded.viewed_mode,
               viewed_global = excluded.viewed_global, updated_at = excluded.updated_at,
               deleted = excluded.deleted, seq = excluded.seq,
               deleted_at = excluded.deleted_at, deleted_by = excluded.deleted_by",
            params![
                id, user_id, kind, title, payload_s, parent_id, viewed_mode.as_str(),
                viewed_global as i64, created_at, client_updated_at, created_by, deleted as i64, seq,
                deleted_at, deleted_by
            ],
        )?;
        let b = Self::get_block_inner(&conn, user_id, id)?.expect("just inserted");
        Ok(UpsertOutcome::Applied(b))
    }

    /// Set viewed state honouring block's viewed_mode.
    /// Returns (block_after, device_scope, seq) where device_scope is Some(device) for per-device.
    pub fn set_viewed(
        &self,
        user_id: &str,
        device_id: &str,
        block_id: &str,
        viewed: bool,
    ) -> rusqlite::Result<Option<(Block, Option<String>, i64)>> {
        let conn = self.conn.lock().unwrap();
        let Some(block) = Self::get_block_inner(&conn, user_id, block_id)? else {
            return Ok(None);
        };
        let seq = Self::next_seq(&conn, user_id)?;
        match block.viewed_mode {
            ViewedMode::Global => {
                conn.execute(
                    "UPDATE blocks SET viewed_global = ?1, seq = ?2 WHERE user_id = ?3 AND id = ?4",
                    params![viewed as i64, seq, user_id, block_id],
                )?;
                let b = Self::get_block_inner(&conn, user_id, block_id)?.unwrap();
                Ok(Some((b, None, seq)))
            }
            ViewedMode::PerDevice => {
                conn.execute(
                    "INSERT INTO device_views(user_id, block_id, device_id, viewed, updated_at, seq)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                     ON CONFLICT(user_id, block_id, device_id) DO UPDATE SET
                       viewed = excluded.viewed, updated_at = excluded.updated_at, seq = excluded.seq",
                    params![user_id, block_id, device_id, viewed as i64, now_ms(), seq],
                )?;
                Ok(Some((block, Some(device_id.to_string()), seq)))
            }
        }
    }

    pub fn device_viewed(
        &self,
        user_id: &str,
        device_id: &str,
        block_id: &str,
    ) -> rusqlite::Result<bool> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(
                "SELECT viewed FROM device_views WHERE user_id = ?1 AND device_id = ?2 AND block_id = ?3",
                params![user_id, device_id, block_id],
                |r| r.get::<_, i64>(0),
            )
            .optional()?
            .map(|v| v != 0)
            .unwrap_or(false))
    }

    pub fn blocks_since(&self, user_id: &str, since_seq: i64) -> rusqlite::Result<Vec<Block>> {
        let conn = self.conn.lock().unwrap();
        let mut st =
            conn.prepare("SELECT * FROM blocks WHERE user_id = ?1 AND seq > ?2 ORDER BY seq ASC")?;
        let rows = st.query_map(params![user_id, since_seq], row_to_block)?;
        rows.collect()
    }

    /// Per-device views for this device with seq > since.
    pub fn device_views_since(
        &self,
        user_id: &str,
        device_id: &str,
        since_seq: i64,
    ) -> rusqlite::Result<Vec<(String, bool, i64)>> {
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare(
            "SELECT block_id, viewed, seq FROM device_views WHERE user_id = ?1 AND device_id = ?2 AND seq > ?3 ORDER BY seq",
        )?;
        let rows = st.query_map(params![user_id, device_id, since_seq], |r| {
            Ok((r.get(0)?, r.get::<_, i64>(1)? != 0, r.get(2)?))
        })?;
        rows.collect()
    }

    pub fn latest_seq(&self, user_id: &str) -> rusqlite::Result<i64> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(
                "SELECT seq FROM counters WHERE user_id = ?1",
                params![user_id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0))
    }

    // ---------- recycle bin ----------

    /// Permanently delete `root` and all its descendants (tombstones, new seq each).
    /// Returns every block that changed state (root included if it wasn't already a tombstone),
    /// plus the root itself when it was already a tombstone so callers can clean its blob.
    pub fn purge_tree(&self, user_id: &str, root: &str) -> rusqlite::Result<Vec<Block>> {
        let conn = self.conn.lock().unwrap();
        let mut out = Vec::new();
        let mut stack = vec![root.to_string()];
        let mut seen = std::collections::HashSet::new();
        while let Some(id) = stack.pop() {
            if !seen.insert(id.clone()) {
                continue;
            }
            if let Some(b) = Self::get_block_inner(&conn, user_id, &id)? {
                if !b.deleted {
                    let seq = Self::next_seq(&conn, user_id)?;
                    conn.execute(
                        "UPDATE blocks SET deleted = 1, seq = ?1, updated_at = MAX(updated_at, ?2)
                         WHERE user_id = ?3 AND id = ?4",
                        params![seq, now_ms(), user_id, id],
                    )?;
                    out.push(Self::get_block_inner(&conn, user_id, &id)?.unwrap());
                } else if id == root {
                    out.push(b);
                }
            }
            let mut st =
                conn.prepare("SELECT id FROM blocks WHERE user_id = ?1 AND parent_id = ?2")?;
            let kids = st.query_map(params![user_id, id], |r| r.get::<_, String>(0))?;
            for k in kids {
                stack.push(k?);
            }
        }
        Ok(out)
    }

    /// Recycle-bin entries (user_id, block_id) trashed before `cutoff_ms`.
    pub fn expired_trash(&self, cutoff_ms: i64) -> rusqlite::Result<Vec<(String, String)>> {
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare(
            "SELECT user_id, id FROM blocks WHERE deleted = 0 AND deleted_at IS NOT NULL AND deleted_at < ?1",
        )?;
        let rows = st.query_map(params![cutoff_ms], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect()
    }
}
