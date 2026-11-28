//! Account backup and restore.
//!
//! The zip format is the same as `admin export` / client「导出我的数据」:
//! `syncnotes-export` with `manifest.json`, `blocks.json`, optional
//! `device_views.json`, `pending_outbox.json`, `files/*`, and `markdown/**`.
//! Restore writes the archive into the *currently authenticated* account so
//! a user can migrate between accounts or servers. It never encrypts data at
//! rest and never touches the password, recovery code, or login tokens.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::admin::{self, ExportSummary};
use crate::blocks::{valid_kind, ViewedMode};
use crate::storage::Storage;

pub type BackupResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// One block as it appears in `blocks.json` or a pending upsert.
#[derive(Debug, Clone, Deserialize)]
pub struct RestoreBlock {
    pub id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub payload: Value,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub viewed_mode: ViewedMode,
    #[serde(default)]
    pub viewed_global: bool,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub updated_at: i64,
    #[serde(default)]
    pub created_by: String,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub deleted_at: Option<i64>,
    #[serde(default)]
    pub deleted_by: Option<String>,
}

/// Device-view row from `device_views.json`.
#[derive(Debug, Clone, Deserialize)]
struct RawView {
    block_id: String,
    device_id: String,
    #[serde(default)]
    viewed: bool,
}

#[derive(Debug, Clone, Default)]
pub struct RestoreDbSummary {
    pub blocks: usize,
    pub tombstoned: usize,
    pub views: usize,
    pub latest_seq: i64,
}

#[derive(Debug, Clone)]
pub struct RestoreSummary {
    pub blocks: usize,
    pub trashed: usize,
    pub tombstoned: usize,
    pub files: usize,
    pub missing_files: usize,
    pub views: usize,
    pub pending_applied: usize,
    pub latest_seq: i64,
    pub safety_backup: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ManifestInfo {
    pub format: String,
    pub version: i64,
    pub source: Option<String>,
    pub username: Option<String>,
    pub exported_at: Option<String>,
    pub blocks: usize,
    pub files: usize,
}

const MAX_UNCOMPRESSED: u64 = crate::files::MAX_FILE_BYTES;
const MAX_ENTRIES: usize = 100_000;
const MAX_JSON_BYTES: u64 = 64 * 1024 * 1024;
const PRE_RESTORE_KEEP: usize = 3;

fn hex32(bytes: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(H[(b >> 4) as usize] as char);
        out.push(H[(b & 0xf) as usize] as char);
    }
    out
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 80
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn pre_restore_dir(files_dir: &Path, user_id: &str) -> PathBuf {
    files_dir.join(user_id).join(".pre-restore")
}

/// Write a safety zip of the current account (same format as `admin export`)
/// and keep only the newest [PRE_RESTORE_KEEP] copies.
pub fn safety_backup(
    st: &Storage,
    files_dir: &Path,
    username: &str,
    user_id: &str,
) -> BackupResult<PathBuf> {
    let dir = pre_restore_dir(files_dir, user_id);
    std::fs::create_dir_all(&dir).map_err(err)?;
    let ts = chrono::Local::now().format("%Y%m%d-%H%M%S");
    let out = dir.join(format!("pre-restore-{ts}.zip"));
    // If two restores happen in the same second, don't collide.
    let out = if out.exists() {
        dir.join(format!("pre-restore-{ts}-{}.zip", uuid::Uuid::new_v4()))
    } else {
        out
    };
    admin::export_user(st, files_dir, username, &out)?;
    prune_safety_backups(&dir)?;
    Ok(out)
}

fn prune_safety_backups(dir: &Path) -> BackupResult<()> {
    let mut zips: Vec<PathBuf> = std::fs::read_dir(dir)
        .map_err(err)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("zip"))
        .collect();
    zips.sort_by_key(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok());
    while zips.len() > PRE_RESTORE_KEEP {
        let old = zips.remove(0);
        let _ = std::fs::remove_file(old);
    }
    Ok(())
}

/// Inspect a zip without applying it.
pub fn inspect_zip(path: &Path) -> BackupResult<ManifestInfo> {
    let parsed = open_archive(path)?;
    Ok(parsed.manifest)
}

struct ParsedArchive {
    manifest: ManifestInfo,
    blocks: Vec<RestoreBlock>,
    views: Vec<(String, String, bool)>,
    pending: Vec<Value>,
    /// file_id -> bytes
    files: HashMap<String, Vec<u8>>,
}

fn open_archive(path: &Path) -> BackupResult<ParsedArchive> {
    let f = File::open(path).map_err(|e| format!("无法打开备份文件: {e}"))?;
    let mut zip = zip::ZipArchive::new(f).map_err(|e| format!("不是有效的 zip 备份: {e}"))?;
    if zip.len() > MAX_ENTRIES {
        return Err("备份文件条目过多".into());
    }
    let mut total = 0u64;
    for i in 0..zip.len() {
        let entry = zip.by_index(i).map_err(err)?;
        if entry.enclosed_name().is_none() {
            return Err(format!("备份包含非法路径: {}", entry.name()));
        }
        total = total.saturating_add(entry.size());
        if total > MAX_UNCOMPRESSED {
            return Err("备份解压后超过 4 GB 上限".into());
        }
    }

    let manifest_bytes = read_entry(&mut zip, "manifest.json", MAX_JSON_BYTES)?;
    let manifest_v: Value = serde_json::from_slice(&manifest_bytes)
        .map_err(|_| "manifest.json 不是有效的 JSON".to_string())?;
    let format = manifest_v
        .get("format")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if format != "syncnotes-export" && format != "syncnotes-backup" {
        return Err(format!(
            "无法识别的备份格式（需要 syncnotes-export，实际是 {format:?}）"
        ));
    }
    let manifest = ManifestInfo {
        format,
        version: manifest_v
            .get("version")
            .and_then(Value::as_i64)
            .unwrap_or(1),
        source: manifest_v
            .get("source")
            .and_then(Value::as_str)
            .map(|s| s.to_string()),
        username: manifest_v
            .get("username")
            .and_then(Value::as_str)
            .map(|s| s.to_string()),
        exported_at: manifest_v
            .get("exported_at")
            .and_then(Value::as_str)
            .map(|s| s.to_string()),
        blocks: manifest_v
            .get("blocks")
            .and_then(Value::as_u64)
            .unwrap_or(0) as usize,
        files: manifest_v.get("files").and_then(Value::as_u64).unwrap_or(0) as usize,
    };

    let blocks_bytes = read_entry(&mut zip, "blocks.json", MAX_JSON_BYTES)?;
    let raw_blocks: Vec<Value> = serde_json::from_slice(&blocks_bytes)
        .map_err(|_| "blocks.json 不是有效的 JSON 数组".to_string())?;
    let mut blocks = Vec::with_capacity(raw_blocks.len());
    let mut seen = HashSet::new();
    for v in raw_blocks {
        let b: RestoreBlock =
            serde_json::from_value(v).map_err(|e| format!("blocks.json 中有无法解析的块: {e}"))?;
        if !valid_id(&b.id) {
            return Err(format!("块 id 非法: {}", b.id));
        }
        let kind = if b.kind.is_empty() {
            "note".into()
        } else {
            b.kind.clone()
        };
        if !valid_kind(&kind) {
            return Err(format!("块 {} 的类型非法: {}", b.id, kind));
        }
        if !seen.insert(b.id.clone()) {
            return Err(format!("blocks.json 中有重复的块 id: {}", b.id));
        }
        let mut b = b;
        b.kind = kind;
        if b.payload.is_null() {
            b.payload = json!({});
        }
        blocks.push(b);
    }

    let views = match read_entry_optional(&mut zip, "device_views.json", MAX_JSON_BYTES)? {
        Some(bytes) if !bytes.is_empty() => {
            let raw: Vec<RawView> = serde_json::from_slice(&bytes)
                .map_err(|_| "device_views.json 不是有效的 JSON".to_string())?;
            raw.into_iter()
                .filter(|v| {
                    valid_id(&v.block_id) && !v.device_id.is_empty() && v.device_id.len() <= 128
                })
                .map(|v| (v.block_id, v.device_id, v.viewed))
                .collect()
        }
        _ => Vec::new(),
    };

    let pending = match read_entry_optional(&mut zip, "pending_outbox.json", MAX_JSON_BYTES)? {
        Some(bytes) if !bytes.is_empty() => serde_json::from_slice(&bytes)
            .map_err(|_| "pending_outbox.json 不是有效的 JSON".to_string())?,
        _ => Vec::new(),
    };

    // Map file_id -> zip entry path from block payloads, then read bytes.
    let mut file_names: HashMap<String, String> = HashMap::new();
    let names: Vec<String> = zip.file_names().map(|s| s.to_string()).collect();
    for b in &blocks {
        if let Some(fid) = file_id_of(&b.payload) {
            if let Some(rel) = names.iter().find(|n| {
                let n = n.replace('\\', "/");
                n.starts_with("files/") && n.contains(&fid[..fid.len().min(8)])
            }) {
                file_names.insert(fid, rel.clone());
            }
        }
    }
    // Also accept a direct files/{file_id} layout.
    for n in &names {
        let n_norm = n.replace('\\', "/");
        if let Some(rest) = n_norm.strip_prefix("files/") {
            if !rest.is_empty() && !rest.contains('/') && valid_id(rest) {
                file_names
                    .entry(rest.to_string())
                    .or_insert_with(|| n.clone());
            }
        }
    }

    let mut files = HashMap::new();
    for (fid, rel) in file_names {
        if !valid_id(&fid) {
            continue;
        }
        match read_entry(&mut zip, &rel, MAX_UNCOMPRESSED) {
            Ok(bytes) => {
                files.insert(fid, bytes);
            }
            Err(_) => {
                // Counted as missing later if a live block still references it.
            }
        }
    }

    Ok(ParsedArchive {
        manifest,
        blocks,
        views,
        pending,
        files,
    })
}

fn file_id_of(payload: &Value) -> Option<String> {
    let fid = payload.get("file_id").and_then(Value::as_str)?;
    if valid_id(fid) {
        Some(fid.to_string())
    } else {
        None
    }
}

fn read_entry(zip: &mut zip::ZipArchive<File>, name: &str, max: u64) -> BackupResult<Vec<u8>> {
    read_entry_optional(zip, name, max)?.ok_or_else(|| format!("备份缺少 {name}"))
}

fn read_entry_optional(
    zip: &mut zip::ZipArchive<File>,
    name: &str,
    max: u64,
) -> BackupResult<Option<Vec<u8>>> {
    match zip.by_name(name) {
        Ok(mut f) => {
            if f.enclosed_name().is_none() {
                return Err(format!("备份包含非法路径: {name}"));
            }
            if f.size() > max {
                return Err(format!("{name} 过大"));
            }
            let mut buf = Vec::with_capacity(f.size() as usize);
            f.read_to_end(&mut buf).map_err(err)?;
            Ok(Some(buf))
        }
        Err(zip::result::ZipError::FileNotFound) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

fn apply_pending(
    blocks: &mut Vec<RestoreBlock>,
    views: &mut Vec<(String, String, bool)>,
    pending: &[Value],
) -> BackupResult<usize> {
    let mut applied = 0usize;
    for op in pending {
        let typ = op.get("type").and_then(Value::as_str).unwrap_or("");
        match typ {
            "upsert_block" => {
                let mut b: RestoreBlock = serde_json::from_value(op.clone())
                    .map_err(|e| format!("pending_outbox 中有无法解析的修改: {e}"))?;
                if !valid_id(&b.id) {
                    return Err(format!("未同步修改的块 id 非法: {}", b.id));
                }
                if b.kind.is_empty() {
                    b.kind = "note".into();
                }
                if !valid_kind(&b.kind) {
                    return Err(format!("未同步修改的块类型非法: {}", b.kind));
                }
                // Prefer client_updated_at when present (upsert wire format).
                if let Some(t) = op.get("client_updated_at").and_then(Value::as_i64) {
                    if t > 0 {
                        b.updated_at = t;
                    }
                }
                if let Some(i) = blocks.iter().position(|x| x.id == b.id) {
                    blocks[i] = b;
                } else {
                    blocks.push(b);
                }
                applied += 1;
            }
            "set_viewed" => {
                let bid = op
                    .get("block_id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if !valid_id(&bid) {
                    continue;
                }
                let viewed = op.get("viewed") == Some(&json!(true));
                // No device_id on the wire: treat as a global flag on the block.
                if let Some(b) = blocks.iter_mut().find(|x| x.id == bid) {
                    if matches!(b.viewed_mode, ViewedMode::Global) {
                        b.viewed_global = viewed;
                    }
                }
                // Keep any existing per-device rows; a restore without device_id
                // cannot invent one. Still counts as applied if we touched the block.
                let _ = views;
                applied += 1;
            }
            "" | "auth" | "sync_since" | "ping" => {}
            _ => {
                // Ignore unknown ops so older / newer clients can still restore.
            }
        }
    }
    Ok(applied)
}

/// Restore `zip_path` into `username`'s account. Writes a safety backup first.
/// On any error before the database transaction commits, the account is unchanged.
pub fn restore_from_zip(
    st: &Storage,
    files_dir: &Path,
    username: &str,
    zip_path: &Path,
) -> BackupResult<RestoreSummary> {
    let user = st
        .find_user(username)
        .map_err(err)?
        .ok_or_else(|| format!("用户不存在: {username}"))?;
    let parsed = open_archive(zip_path)?;
    let mut blocks = parsed.blocks;
    let mut views = parsed.views;
    let pending_applied = apply_pending(&mut blocks, &mut views, &parsed.pending)?;

    let safety = safety_backup(st, files_dir, username, &user.id)?;

    // Stage files first so a disk error cannot leave the DB half-applied.
    let staging = files_dir
        .join(&user.id)
        .join(format!(".restore-staging-{}", uuid::Uuid::new_v4()));
    if let Err(e) = std::fs::create_dir_all(&staging) {
        return Err(format!("无法准备附件目录: {e}"));
    }
    let mut written: HashMap<String, (PathBuf, String)> = HashMap::new();
    let mut missing = 0usize;
    for b in &blocks {
        if b.deleted {
            continue;
        }
        let Some(fid) = file_id_of(&b.payload) else {
            continue;
        };
        match parsed.files.get(&fid) {
            Some(bytes) => {
                if written.contains_key(&fid) {
                    continue;
                }
                let dest = staging.join(&fid);
                if let Err(e) = std::fs::write(&dest, bytes) {
                    let _ = std::fs::remove_dir_all(&staging);
                    return Err(format!("写入附件失败: {e}"));
                }
                let sha = hex32(&Sha256::digest(bytes));
                written.insert(fid, (dest, sha));
            }
            None => missing += 1,
        }
    }

    let db = match st.restore_account(&user.id, &blocks, &views) {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&staging);
            return Err(format!("还原数据失败: {e}"));
        }
    };

    // Move staged files into the live directory, then drop unreferenced blobs.
    let live_dir = files_dir.join(&user.id);
    if let Err(e) = std::fs::create_dir_all(&live_dir) {
        return Err(format!("无法写入附件目录: {e}"));
    }
    for (fid, (src, sha)) in &written {
        let dest = live_dir.join(fid);
        if let Err(e) = std::fs::rename(src, &dest) {
            if let Err(e2) = std::fs::copy(src, &dest).and_then(|_| std::fs::remove_file(src)) {
                return Err(format!("安装附件失败: {e} / {e2}"));
            }
        }
        let _ = std::fs::write(live_dir.join(format!("{fid}.sha256")), sha.as_bytes());
    }
    let _ = std::fs::remove_dir_all(&staging);

    let referenced: HashSet<String> = blocks
        .iter()
        .filter_map(|b| file_id_of(&b.payload))
        .collect();
    if let Ok(entries) = std::fs::read_dir(&live_dir) {
        for ent in entries.flatten() {
            let path = ent.path();
            let name = ent.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') {
                continue;
            }
            if let Some(stem) = name.strip_suffix(".sha256") {
                if !referenced.contains(stem) {
                    let _ = std::fs::remove_file(&path);
                }
                continue;
            }
            if ent.file_type().map(|t| t.is_file()).unwrap_or(false)
                && !referenced.contains(name.as_ref())
            {
                let _ = std::fs::remove_file(&path);
                let _ = std::fs::remove_file(live_dir.join(format!("{name}.sha256")));
            }
        }
    }

    let trashed = blocks
        .iter()
        .filter(|b| !b.deleted && b.deleted_at.is_some())
        .count();
    Ok(RestoreSummary {
        blocks: db.blocks,
        trashed,
        tombstoned: db.tombstoned,
        files: written.len(),
        missing_files: missing,
        views: db.views,
        pending_applied,
        latest_seq: db.latest_seq,
        safety_backup: safety,
    })
}

/// Re-export of the existing admin export for callers that want a typed alias.
pub fn export_user(
    st: &Storage,
    files_dir: &Path,
    username: &str,
    out: &Path,
) -> BackupResult<ExportSummary> {
    admin::export_user(st, files_dir, username, out)
}

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;

use crate::protocol::{RestoreRequest, ServerMessage};
use crate::state::AppState;

fn bearer_user(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(String, String), (StatusCode, String)> {
    let t = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or((StatusCode::UNAUTHORIZED, "缺少令牌".into()))?;
    let (uid, _) = state
        .storage
        .validate_token(t)
        .ok()
        .flatten()
        .ok_or((StatusCode::UNAUTHORIZED, "无效令牌".into()))?;
    let user = state
        .storage
        .find_user_by_id(&uid)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .ok_or((StatusCode::UNAUTHORIZED, "无效令牌".into()))?;
    Ok((user.id, user.username))
}

/// POST /api/restore — replace the current account with the backup zip at `file_id`.
pub async fn restore_http(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RestoreRequest>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let (uid, username) = bearer_user(&state, &headers)?;
    if !valid_id(&req.file_id) {
        return Err((StatusCode::BAD_REQUEST, "非法文件 id".into()));
    }
    let zip_path = state.files_dir.join(&uid).join(&req.file_id);
    if !zip_path.is_file() {
        return Err((
            StatusCode::NOT_FOUND,
            "找不到要恢复的备份文件，请重新上传".into(),
        ));
    }
    let storage = state.storage.clone();
    let files_dir = state.files_dir.clone();
    let zip_path_task = zip_path.clone();
    let username_task = username.clone();
    let result = tokio::task::spawn_blocking(move || {
        restore_from_zip(&storage, &files_dir, &username_task, &zip_path_task)
    })
    .await
    .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, "还原任务失败".into()))?;
    // Always drop the uploaded zip, whether restore succeeded or not, so it
    // does not linger as a regular attachment.
    let _ = std::fs::remove_file(&zip_path);
    let _ = std::fs::remove_file(
        state
            .files_dir
            .join(&uid)
            .join(format!("{}.sha256", req.file_id)),
    );
    let summary = result.map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    state.broadcast_user(
        &uid,
        &ServerMessage::Resync {
            latest_seq: summary.latest_seq,
        },
    );
    Ok(Json(json!({
        "ok": true,
        "blocks": summary.blocks,
        "trashed": summary.trashed,
        "tombstoned": summary.tombstoned,
        "files": summary.files,
        "missing_files": summary.missing_files,
        "views": summary.views,
        "pending_applied": summary.pending_applied,
        "latest_seq": summary.latest_seq,
        "safety_backup": true,
    })))
}
