//! 管理员救援 (offline admin rescue): list users, reset password, export a user's data, backup.
//!
//! Works directly on the SQLite file. The database is in WAL mode with a busy timeout, so these
//! commands are safe while the server is running; revoked tokens are noticed by the running
//! server within ~15 s (live WebSockets are closed).

use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::auth::{generate_temp_password, hash_password, validate_password};
use crate::blocks::Block;
use crate::storage::{Storage, UserSummary};

pub type AdminResult<T> = Result<T, String>;

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn fmt_ts(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms)
        .map(|d| {
            d.with_timezone(&chrono::Local)
                .format("%Y-%m-%d %H:%M")
                .to_string()
        })
        .unwrap_or_else(|| "-".into())
}

pub fn list_users(st: &Storage) -> AdminResult<Vec<UserSummary>> {
    st.list_users().map_err(err)
}

pub fn format_users(users: &[UserSummary]) -> String {
    let mut s = format!(
        "{:<20} {:>6} {:>6} {:>6} {:<8} {:<10} {}\n",
        "用户名", "块数", "回收站", "会话", "恢复码", "需改密码", "注册时间"
    );
    for u in users {
        s.push_str(&format!(
            "{:<20} {:>6} {:>6} {:>6} {:<8} {:<10} {}\n",
            u.username,
            u.blocks,
            u.trashed,
            u.tokens,
            if u.has_recovery_code { "有" } else { "无" },
            if u.must_change_password { "是" } else { "否" },
            fmt_ts(u.created_at)
        ));
    }
    if users.is_empty() {
        s.push_str("（没有用户）\n");
    }
    s
}

pub struct ResetOutcome {
    pub password: String,
    pub generated: bool,
    pub revoked_tokens: i64,
}

/// Reset a user's password. `password=None` generates a temporary one. Only the password hash,
/// the must-change flag and the user's tokens change: user id, blocks, files, recycle bin and
/// read state are untouched (no data is derived from or encrypted with the password).
pub fn reset_password(
    st: &Storage,
    username: &str,
    password: Option<String>,
    force_change: bool,
) -> AdminResult<ResetOutcome> {
    let user = st
        .find_user(username)
        .map_err(err)?
        .ok_or_else(|| format!("用户不存在: {username}"))?;
    let (password, generated) = match password {
        Some(p) => {
            validate_password(&p)?;
            (p, false)
        }
        None => (generate_temp_password(), true),
    };
    let revoked = st.token_count(&user.id).map_err(err)?;
    st.set_password(&user.id, &hash_password(&password), force_change, None)
        .map_err(err)?;
    Ok(ResetOutcome {
        password,
        generated,
        revoked_tokens: revoked,
    })
}

pub struct ExportSummary {
    pub blocks: usize,
    pub trashed: usize,
    pub files: usize,
    pub missing_files: usize,
    pub out: PathBuf,
}

/// Make a string safe as a single path component inside the zip.
pub fn safe_name(s: &str) -> String {
    let n: String = s
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    let n = n.trim().trim_matches('.').to_string();
    let n: String = n.chars().take(80).collect();
    if n.is_empty() {
        "untitled".into()
    } else {
        n
    }
}

fn str_of<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

fn order_of(b: &Block) -> f64 {
    b.payload
        .get("order")
        .and_then(Value::as_f64)
        .unwrap_or(b.created_at as f64)
}

/// Archive-relative path of a file blob, if the block references one.
fn file_entry(b: &Block) -> Option<(String, String)> {
    let fid = str_of(&b.payload, "file_id");
    if fid.is_empty() || !fid.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
        return None;
    }
    let name = b
        .payload
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or(&b.title);
    Some((
        fid.to_string(),
        format!("files/{}-{}", &fid[..fid.len().min(8)], safe_name(name)),
    ))
}

fn render_md(
    b: &Block,
    kids: &HashMap<String, Vec<&Block>>,
    files: &HashMap<String, String>,
    depth: usize,
    out: &mut String,
) {
    let p = &b.payload;
    let text = {
        let t = str_of(p, "text");
        if !t.is_empty() {
            t.to_string()
        } else {
            str_of(p, "markdown").to_string()
        }
    };
    let ind = "  ".repeat(depth.saturating_sub(1));
    let link = |rel: &str| format!("../{rel}");
    if depth == 0 {
        let icon = str_of(p, "icon");
        out.push_str(&format!(
            "# {}{}\n\n",
            if icon.is_empty() {
                String::new()
            } else {
                format!("{icon} ")
            },
            if b.title.is_empty() {
                "无标题"
            } else {
                &b.title
            }
        ));
        if b.deleted_at.is_some() {
            out.push_str(&format!(
                "> 回收站项目（删除于 {}）\n\n",
                fmt_ts(b.deleted_at.unwrap_or(0))
            ));
        }
        if !text.is_empty() {
            out.push_str(&text);
            out.push_str("\n\n");
        }
    } else if let Some(rel) = files.get(&b.id) {
        let name = p.get("name").and_then(Value::as_str).unwrap_or(&b.title);
        out.push_str(&format!("{ind}[📎 {name}]({})\n\n", link(rel)));
    } else {
        let line = match str_of(p, "type") {
            "h1" => format!("## {text}"),
            "h2" => format!("### {text}"),
            "h3" => format!("#### {text}"),
            "bullet" => format!("{ind}- {text}"),
            "numbered" => format!("{ind}1. {text}"),
            "todo" => format!(
                "{ind}- [{}] {text}",
                if p.get("checked") == Some(&json!(true)) {
                    "x"
                } else {
                    " "
                }
            ),
            "toggle" => format!("{ind}▸ {text}"),
            "quote" => format!("> {text}"),
            "callout" => format!("> {} {text}", {
                let i = str_of(p, "icon");
                if i.is_empty() {
                    "💡"
                } else {
                    i
                }
            }),
            "code" => format!("```{}\n{text}\n```", str_of(p, "lang")),
            "divider" => "---".into(),
            _ if b.kind == "folder" || b.kind == "page" => {
                format!(
                    "{ind}- 📄 {}",
                    if b.title.is_empty() {
                        "无标题"
                    } else {
                        &b.title
                    }
                )
            }
            _ if text.is_empty() => format!("{ind}{}", b.title),
            _ => format!("{ind}{text}"),
        };
        out.push_str(&line);
        out.push_str("\n\n");
    }
    if let Some(cs) = kids.get(&b.id) {
        for c in cs {
            render_md(c, kids, files, depth + 1, out);
        }
    }
}

/// Export every block of `username` (live + recycle bin + tombstones) to a zip:
/// `manifest.json`, `blocks.json`, `device_views.json`, `markdown/**.md`, `files/*`.
pub fn export_user(
    st: &Storage,
    files_dir: &Path,
    username: &str,
    out: &Path,
) -> AdminResult<ExportSummary> {
    let user = st
        .find_user(username)
        .map_err(err)?
        .ok_or_else(|| format!("用户不存在: {username}"))?;
    let blocks = st.all_blocks(&user.id).map_err(err)?;
    let views = st.all_device_views(&user.id).map_err(err)?;
    if let Some(dir) = out.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(err)?;
    }
    let tmp = out.with_extension("zip.partial");
    let f = std::fs::File::create(&tmp).map_err(|e| format!("无法创建 {}: {e}", tmp.display()))?;
    let mut zip = zip::ZipWriter::new(f);
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o600);

    let live: Vec<&Block> = blocks.iter().filter(|b| !b.deleted).collect();
    let trashed = live.iter().filter(|b| b.deleted_at.is_some()).count();

    // Files
    let mut file_paths: HashMap<String, String> = HashMap::new();
    let (mut nfiles, mut missing) = (0, 0);
    let user_files = files_dir.join(&user.id);
    for b in &live {
        if let Some((fid, rel)) = file_entry(b) {
            match std::fs::read(user_files.join(&fid)) {
                Ok(data) => {
                    zip.start_file(rel.as_str(), opts).map_err(err)?;
                    zip.write_all(&data).map_err(err)?;
                    file_paths.insert(b.id.clone(), rel);
                    nfiles += 1;
                }
                Err(_) => missing += 1,
            }
        }
    }

    // JSON
    let manifest = json!({
        "format": "syncnotes-export",
        "version": 1,
        "source": "server-admin",
        "username": user.username,
        "user_id": user.id,
        "exported_at": chrono::Utc::now().to_rfc3339(),
        "blocks": blocks.len(),
        "live_blocks": live.len(),
        "trashed_blocks": trashed,
        "files": nfiles,
        "missing_files": missing,
    });
    zip.start_file("manifest.json", opts).map_err(err)?;
    zip.write_all(
        serde_json::to_string_pretty(&manifest)
            .map_err(err)?
            .as_bytes(),
    )
    .map_err(err)?;
    zip.start_file("blocks.json", opts).map_err(err)?;
    zip.write_all(
        serde_json::to_string_pretty(&blocks)
            .map_err(err)?
            .as_bytes(),
    )
    .map_err(err)?;
    let views_json: Vec<Value> = views
        .iter()
        .map(|(b, d, v)| json!({"block_id": b, "device_id": d, "viewed": v}))
        .collect();
    zip.start_file("device_views.json", opts).map_err(err)?;
    zip.write_all(
        serde_json::to_string_pretty(&views_json)
            .map_err(err)?
            .as_bytes(),
    )
    .map_err(err)?;

    // Markdown: one file per root (block without a live parent); trash roots in 回收站/.
    let ids: std::collections::HashSet<&str> = live.iter().map(|b| b.id.as_str()).collect();
    let mut kids: HashMap<String, Vec<&Block>> = HashMap::new();
    let mut roots: Vec<&Block> = Vec::new();
    for b in &live {
        match b
            .parent_id
            .as_deref()
            .filter(|p| ids.contains(p) && *p != b.id)
        {
            Some(p) => kids.entry(p.to_string()).or_default().push(b),
            None => roots.push(b),
        }
    }
    for v in kids.values_mut() {
        v.sort_by(|a, b| order_of(a).total_cmp(&order_of(b)));
    }
    roots.sort_by_key(|b| b.created_at);
    let mut used: BTreeMap<String, usize> = BTreeMap::new();
    for r in roots {
        let mut md = String::new();
        render_md(r, &kids, &file_paths, 0, &mut md);
        let dir = if r.deleted_at.is_some() {
            "markdown/回收站"
        } else {
            "markdown"
        };
        let base = format!(
            "{dir}/{}",
            safe_name(if r.title.is_empty() { &r.id } else { &r.title })
        );
        let n = used.entry(base.clone()).or_insert(0);
        *n += 1;
        let path = if *n == 1 {
            format!("{base}.md")
        } else {
            format!("{base} ({n}).md")
        };
        // Markdown in subfolders links files relative to the archive root.
        let md = if dir.ends_with("回收站") {
            md.replace("](../files/", "](../../files/")
        } else {
            md
        };
        zip.start_file(path.as_str(), opts).map_err(err)?;
        zip.write_all(md.as_bytes()).map_err(err)?;
    }
    zip.finish().map_err(err)?;
    std::fs::rename(&tmp, out).map_err(err)?;
    Ok(ExportSummary {
        blocks: blocks.len(),
        trashed,
        files: nfiles,
        missing_files: missing,
        out: out.to_path_buf(),
    })
}

pub fn backup(st: &Storage, out: &Path) -> AdminResult<()> {
    if out.exists() {
        return Err(format!("目标已存在: {}", out.display()));
    }
    st.backup_to(out).map_err(err)
}
