//! One-click backup / restore: zip format, force-replace, safety backup, HTTP API.

use std::io::{Cursor, Read, Write};
use std::net::SocketAddr;
use std::path::PathBuf;

use serde_json::{json, Value};
use syncnotes_server::blocks::ViewedMode;
use syncnotes_server::storage::UpsertOutcome;
use syncnotes_server::{admin, backup, build_router, AppState, Storage};

#[path = "common/wire.rs"]
mod wire;

fn applied(
    st: &Storage,
    uid: &str,
    id: &str,
    kind: &str,
    title: &str,
    payload: Value,
    ts: i64,
    deleted_at: Option<Option<i64>>,
) {
    match st
        .upsert_block(
            uid,
            "pc",
            id,
            kind,
            title,
            &payload,
            None,
            ViewedMode::Global,
            ts,
            false,
            deleted_at,
        )
        .unwrap()
    {
        UpsertOutcome::Applied(_) | UpsertOutcome::Stale(_) => {}
    }
}

fn read_zip_entry(path: &std::path::Path, name: &str) -> Vec<u8> {
    let mut z = zip::ZipArchive::new(std::fs::File::open(path).unwrap()).unwrap();
    let mut s = Vec::new();
    z.by_name(name).unwrap().read_to_end(&mut s).unwrap();
    s
}

fn write_zip(path: &std::path::Path, files: &[(&str, &[u8])]) {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).unwrap();
    }
    let f = std::fs::File::create(path).unwrap();
    let mut z = zip::ZipWriter::new(f);
    let opts = zip::write::SimpleFileOptions::default();
    for (name, data) in files {
        z.start_file(*name, opts).unwrap();
        z.write_all(data).unwrap();
    }
    z.finish().unwrap();
}

#[test]
fn restore_replaces_account_and_keeps_password() {
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    std::fs::create_dir_all(&files).unwrap();
    let st = Storage::in_memory().unwrap();
    let bill = st.create_user("bill", "hash-bill").unwrap();
    applied(
        &st,
        &bill.id,
        "note-old",
        "note",
        "旧笔记",
        json!({"markdown": "将被覆盖"}),
        200,
        None,
    );
    applied(
        &st,
        &bill.id,
        "only-here",
        "note",
        "只在当前账号",
        json!({"markdown": "应被墓碑"}),
        200,
        None,
    );
    // A file currently on the account that the backup does not include.
    let old_fid = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb";
    applied(
        &st,
        &bill.id,
        "file-old",
        "file",
        "gone.bin",
        json!({"file_id": old_fid, "name": "gone.bin"}),
        200,
        None,
    );
    std::fs::create_dir_all(files.join(&bill.id)).unwrap();
    std::fs::write(files.join(&bill.id).join(old_fid), b"old-bytes").unwrap();

    // Build a backup as if it came from another (or older) account: older timestamps must still win.
    let fid = "cccccccc-1111-2222-3333-dddddddddddd";
    let blocks = json!([
        {
            "id": "note-old",
            "kind": "note",
            "title": "备份里的标题",
            "payload": {"markdown": "备份正文"},
            "viewed_mode": "global",
            "viewed_global": true,
            "created_at": 50,
            "updated_at": 50,
            "created_by": "phone",
            "deleted": false,
            "deleted_at": null
        },
        {
            "id": "note-new",
            "kind": "note",
            "title": "备份新增",
            "payload": {"markdown": "hello"},
            "viewed_mode": "per_device",
            "created_at": 60,
            "updated_at": 60,
            "created_by": "phone",
            "deleted": false
        },
        {
            "id": "in-trash",
            "kind": "note",
            "title": "回收站笔记",
            "payload": {"markdown": "trashed"},
            "viewed_mode": "global",
            "created_at": 40,
            "updated_at": 80,
            "created_by": "pc",
            "deleted": false,
            "deleted_at": 80
        },
        {
            "id": "report",
            "kind": "file",
            "title": "report.pdf",
            "payload": {"file_id": fid, "name": "report.pdf", "size": 4},
            "viewed_mode": "global",
            "created_at": 10,
            "updated_at": 10,
            "created_by": "pc",
            "deleted": false
        }
    ]);
    let manifest = json!({
        "format": "syncnotes-export",
        "version": 1,
        "source": "test",
        "username": "alice",
        "blocks": 4,
        "files": 1
    });
    let zip = dir.path().join("alice.zip");
    write_zip(
        &zip,
        &[
            (
                "manifest.json",
                serde_json::to_vec(&manifest).unwrap().as_slice(),
            ),
            (
                "blocks.json",
                serde_json::to_vec(&blocks).unwrap().as_slice(),
            ),
            (
                "device_views.json",
                br#"[{"block_id":"note-new","device_id":"phone","viewed":true}]"#,
            ),
            ("files/cccccccc-report.pdf", b"PDF!"),
        ],
    );

    let sum = backup::restore_from_zip(&st, &files, "bill", &zip).unwrap();
    assert_eq!(sum.blocks, 4);
    assert_eq!(sum.trashed, 1);
    assert_eq!(sum.files, 1);
    assert_eq!(sum.missing_files, 0);
    assert!(
        sum.tombstoned >= 2,
        "only-here and file-old should be tombstoned, got {}",
        sum.tombstoned
    );
    assert!(
        sum.safety_backup.exists(),
        "safety backup missing: {}",
        sum.safety_backup.display()
    );

    // Password / user id unchanged.
    let after = st.find_user("bill").unwrap().unwrap();
    assert_eq!(after.id, bill.id);
    assert_eq!(after.password_hash, "hash-bill");

    let all = st.all_blocks(&bill.id).unwrap();
    let by_id = |id: &str| all.iter().find(|b| b.id == id).unwrap();
    let note = by_id("note-old");
    assert_eq!(note.title, "备份里的标题");
    assert_eq!(note.payload["markdown"], "备份正文");
    assert_eq!(note.updated_at, 50, "restore must bypass LWW");
    assert_eq!(note.created_by, "phone");
    assert!(!note.deleted);
    assert!(
        by_id("only-here").deleted,
        "leftover block must be tombstoned"
    );
    assert!(by_id("file-old").deleted);
    assert_eq!(by_id("in-trash").deleted_at, Some(80));
    assert!(!by_id("in-trash").deleted);
    assert_eq!(
        std::fs::read(files.join(&bill.id).join(fid)).unwrap(),
        b"PDF!"
    );
    assert!(
        !files.join(&bill.id).join(old_fid).exists(),
        "unreferenced file should be removed"
    );

    let views = st.all_device_views(&bill.id).unwrap();
    assert!(views
        .iter()
        .any(|(b, d, v)| b == "note-new" && d == "phone" && *v));
}

#[test]
fn restore_applies_pending_outbox() {
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    let st = Storage::in_memory().unwrap();
    let bill = st.create_user("bill", "h").unwrap();
    applied(
        &st,
        &bill.id,
        "n1",
        "note",
        "服务器版",
        json!({"markdown": "server"}),
        10,
        None,
    );

    let blocks = json!([{
        "id": "n1", "kind": "note", "title": "备份版", "payload": {"markdown": "backup"},
        "viewed_mode": "global", "created_at": 5, "updated_at": 5, "created_by": "pc", "deleted": false
    }]);
    let pending = json!([{
        "type": "upsert_block", "id": "n1", "kind": "note", "title": "未同步的修改",
        "payload": {"markdown": "offline"}, "viewed_mode": "global",
        "client_updated_at": 99, "deleted": false, "deleted_at": null
    }, {
        "type": "upsert_block", "id": "n2", "kind": "note", "title": "离线新建",
        "payload": {"markdown": "new"}, "viewed_mode": "per_device",
        "client_updated_at": 100, "deleted": false
    }]);
    let zip = dir.path().join("p.zip");
    write_zip(
        &zip,
        &[
            (
                "manifest.json",
                br#"{"format":"syncnotes-export","version":1,"blocks":1}"#,
            ),
            (
                "blocks.json",
                serde_json::to_vec(&blocks).unwrap().as_slice(),
            ),
            (
                "pending_outbox.json",
                serde_json::to_vec(&pending).unwrap().as_slice(),
            ),
        ],
    );
    let sum = backup::restore_from_zip(&st, &files, "bill", &zip).unwrap();
    assert_eq!(sum.pending_applied, 2);
    assert_eq!(sum.blocks, 2);
    let all = st.all_blocks(&bill.id).unwrap();
    let n1 = all.iter().find(|b| b.id == "n1").unwrap();
    assert_eq!(n1.title, "未同步的修改");
    assert_eq!(n1.payload["markdown"], "offline");
    assert_eq!(n1.updated_at, 99);
    assert!(all.iter().any(|b| b.id == "n2" && b.title == "离线新建"));
}

#[test]
fn restore_rejects_bad_zip_and_leaves_data() {
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    let st = Storage::in_memory().unwrap();
    let bill = st.create_user("bill", "h").unwrap();
    applied(&st, &bill.id, "keep", "note", "保留", json!({}), 1, None);

    let zip = dir.path().join("bad.zip");
    write_zip(
        &zip,
        &[
            ("manifest.json", br#"{"format":"not-this","version":1}"#),
            ("blocks.json", b"[]"),
        ],
    );
    let err = backup::restore_from_zip(&st, &files, "bill", &zip).unwrap_err();
    assert!(err.contains("无法识别的备份格式"), "{err}");
    let all = st.all_blocks(&bill.id).unwrap();
    assert_eq!(all.len(), 1);
    assert_eq!(all[0].title, "保留");
    assert!(!all[0].deleted);

    let zip2 = dir.path().join("missing.zip");
    write_zip(&zip2, &[("readme.txt", b"nope")]);
    assert!(backup::restore_from_zip(&st, &files, "bill", &zip2)
        .unwrap_err()
        .contains("缺少"));
}

#[test]
fn inspect_and_reject_path_traversal() {
    let dir = tempfile::tempdir().unwrap();
    let zip = dir.path().join("ok.zip");
    write_zip(
        &zip,
        &[
            (
                "manifest.json",
                br#"{"format":"syncnotes-export","version":1,"username":"bill","blocks":0}"#,
            ),
            ("blocks.json", b"[]"),
        ],
    );
    let info = backup::inspect_zip(&zip).unwrap();
    assert_eq!(info.format, "syncnotes-export");
    assert_eq!(info.username.as_deref(), Some("bill"));

    // Craft a zip whose local-file name is an absolute-ish / traversal path.
    let mut raw = Vec::new();
    {
        let mut z = zip::ZipWriter::new(Cursor::new(&mut raw));
        let opts = zip::write::SimpleFileOptions::default();
        z.start_file("../evil.txt", opts).unwrap();
        z.write_all(b"nope").unwrap();
        z.start_file("manifest.json", opts).unwrap();
        z.write_all(br#"{"format":"syncnotes-export","version":1}"#)
            .unwrap();
        z.start_file("blocks.json", opts).unwrap();
        z.write_all(b"[]").unwrap();
        z.finish().unwrap();
    }
    let evil = dir.path().join("evil.zip");
    std::fs::write(&evil, &raw).unwrap();
    let err = backup::inspect_zip(&evil).unwrap_err();
    assert!(err.contains("非法路径"), "{err}");
}

struct Srv {
    addr: String,
    state: AppState,
    files: PathBuf,
}

async fn spawn() -> Srv {
    let files = tempfile::tempdir().unwrap().keep();
    let state = AppState::new(Storage::in_memory().unwrap(), true).with_files_dir(files.clone());
    let app = build_router(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap()
    });
    Srv {
        addr: format!("127.0.0.1:{}", addr.port()),
        state,
        files,
    }
}

async fn register_login(addr: &str, user: &str, pw: &str, dev: &str) -> String {
    let (st, v) = wire::post_json(
        addr,
        "/api/register",
        None,
        &json!({"username": user, "password": pw}),
    )
    .await;
    assert_eq!(st, 200, "{v}");
    let (st, v) = wire::post_json(
        addr,
        "/api/login",
        None,
        &json!({"username": user, "password": pw, "device_id": dev}),
    )
    .await;
    assert_eq!(st, 200, "{v}");
    v["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn health_advertises_backup_feature() {
    let s = spawn().await;
    let v: Value = reqwest::get(format!("http://{}/health", s.addr))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let feats = v["features"].as_array().unwrap();
    for want in ["backup", "tasks", "calendar", "trash", "seal"] {
        assert!(feats.iter().any(|f| f == want), "missing {want}: {v}");
    }
}

#[tokio::test]
async fn http_backup_export_and_restore_to_other_account() {
    let s = spawn().await;
    let token_a = register_login(&s.addr, "alice", "password1", "pc").await;
    let token_b = register_login(&s.addr, "bob", "password2", "phone").await;

    // Seed alice with a note + attachment, and a leftover note on bob.
    let alice = s.state.storage.find_user("alice").unwrap().unwrap();
    let bob = s.state.storage.find_user("bob").unwrap().unwrap();
    applied(
        &s.state.storage,
        &alice.id,
        "a-note",
        "note",
        "Alice 的笔记",
        json!({"markdown": "from alice"}),
        10,
        None,
    );
    let (st, put) = wire::blob_put(&s.addr, &token_a, "pic.bin", b"hello-file").await;
    assert_eq!(st, 200, "{put}");
    let fid = put["file_id"].as_str().unwrap().to_string();
    applied(
        &s.state.storage,
        &alice.id,
        "a-file",
        "file",
        "pic.bin",
        json!({"file_id": fid, "name": "pic.bin", "size": 10}),
        11,
        None,
    );
    applied(
        &s.state.storage,
        &bob.id,
        "bob-only",
        "note",
        "Bob 现有的",
        json!({"markdown": "will vanish"}),
        20,
        None,
    );

    let (st, zip_bytes) = wire::blob_backup_export(&s.addr, &token_a).await;
    assert_eq!(
        st,
        200,
        "export failed: {}",
        String::from_utf8_lossy(&zip_bytes)
    );
    assert!(zip_bytes.starts_with(b"PK"), "not a zip");
    // Round-trip through the same format as admin export.
    let tmp = tempfile::tempdir().unwrap().keep().join("a.zip");
    std::fs::write(&tmp, &zip_bytes).unwrap();
    let manifest: Value = serde_json::from_slice(&read_zip_entry(&tmp, "manifest.json")).unwrap();
    assert_eq!(manifest["format"], "syncnotes-export");
    assert_eq!(manifest["username"], "alice");
    let blocks: Vec<Value> = serde_json::from_slice(&read_zip_entry(&tmp, "blocks.json")).unwrap();
    assert!(blocks.iter().any(|b| b["id"] == "a-note"));

    // Upload the zip as bob and restore into bob's account (migration).
    let (st, up) = wire::blob_put(&s.addr, &token_b, "backup.zip", &zip_bytes).await;
    assert_eq!(st, 200, "{up}");
    let zip_id = up["file_id"].as_str().unwrap();
    let (st, res) = wire::post_json(
        &s.addr,
        "/api/restore",
        Some(&token_b),
        &json!({"file_id": zip_id}),
    )
    .await;
    assert_eq!(st, 200, "{res}");
    assert_eq!(res["ok"], true);
    assert!(res["blocks"].as_u64().unwrap() >= 2);
    assert!(res["tombstoned"].as_u64().unwrap() >= 1);
    assert_eq!(res["safety_backup"], true);

    // Bob's password is unchanged; data now matches the backup.
    let bob_after = s.state.storage.find_user("bob").unwrap().unwrap();
    assert_eq!(bob_after.id, bob.id);
    let all = s.state.storage.all_blocks(&bob.id).unwrap();
    assert!(all
        .iter()
        .any(|b| b.id == "a-note" && b.title == "Alice 的笔记" && !b.deleted));
    assert!(all.iter().any(|b| b.id == "bob-only" && b.deleted));
    let got = std::fs::read(s.files.join(&bob.id).join(&fid)).unwrap();
    assert_eq!(got, b"hello-file");
    // The uploaded zip itself must not remain as a normal file.
    assert!(!s.files.join(&bob.id).join(zip_id).exists());

    // Alice is untouched.
    let alice_blocks = s.state.storage.all_blocks(&alice.id).unwrap();
    assert!(alice_blocks.iter().any(|b| b.id == "a-note" && !b.deleted));

    // Unauthenticated / bad file_id.
    let (st, v) = wire::post_json(&s.addr, "/api/restore", None, &json!({"file_id": zip_id})).await;
    assert_eq!(st, 401, "{v}");
    let (st, v) = wire::post_json(
        &s.addr,
        "/api/restore",
        Some(&token_b),
        &json!({"file_id": "../etc/passwd"}),
    )
    .await;
    assert_eq!(st, 400, "{v}");
}

#[tokio::test]
async fn restore_broadcasts_resync_to_live_socket() {
    let s = spawn().await;
    let token = register_login(&s.addr, "bill", "password1", "pc").await;
    let uid = s.state.storage.find_user("bill").unwrap().unwrap().id;
    applied(
        &s.state.storage,
        &uid,
        "n1",
        "note",
        "v1",
        json!({"markdown": "v1"}),
        1,
        None,
    );

    let mut ws = wire::Ws::connect(&s.addr).await;
    ws.send_json(&json!({"type": "auth", "token": token, "device_id": "pc"}))
        .await;
    let auth = ws.recv_json().await.unwrap();
    assert_eq!(auth["type"], "auth_ok", "{auth}");

    let zip = tempfile::tempdir().unwrap().keep().join("b.zip");
    write_zip(
        &zip,
        &[
            ("manifest.json", br#"{"format":"syncnotes-export","version":1,"blocks":1}"#),
            ("blocks.json", br#"[{"id":"n1","kind":"note","title":"v2","payload":{"markdown":"v2"},"viewed_mode":"global","created_at":1,"updated_at":1,"created_by":"pc","deleted":false}]"#),
        ],
    );
    let bytes = std::fs::read(&zip).unwrap();
    let (st, up) = wire::blob_put(&s.addr, &token, "b.zip", &bytes).await;
    assert_eq!(st, 200, "{up}");
    let (st, res) = wire::post_json(
        &s.addr,
        "/api/restore",
        Some(&token),
        &json!({"file_id": up["file_id"]}),
    )
    .await;
    assert_eq!(st, 200, "{res}");

    let mut saw = false;
    for _ in 0..16 {
        let Some(msg) = ws.recv_json().await else {
            break;
        };
        if msg["type"] == "resync" {
            saw = true;
            break;
        }
    }
    assert!(saw, "live websocket should receive resync");
}

#[test]
fn admin_export_roundtrip_via_restore() {
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    std::fs::create_dir_all(&files).unwrap();
    let st = Storage::in_memory().unwrap();
    let bill = st.create_user("bill", "h").unwrap();
    applied(
        &st,
        &bill.id,
        "n1",
        "note",
        "工作",
        json!({"markdown": "进展"}),
        3,
        None,
    );
    let fid = "eeeeeeee-1111-2222-3333-ffffffffffff";
    applied(
        &st,
        &bill.id,
        "f1",
        "file",
        "a.txt",
        json!({"file_id": fid, "name": "a.txt"}),
        4,
        None,
    );
    std::fs::create_dir_all(files.join(&bill.id)).unwrap();
    std::fs::write(files.join(&bill.id).join(fid), b"abc").unwrap();
    let out = dir.path().join("export.zip");
    admin::export_user(&st, &files, "bill", &out).unwrap();

    // Wipe the account visually by adding a different note, then restore the export.
    applied(&st, &bill.id, "extra", "note", "多余", json!({}), 99, None);
    let sum = backup::restore_from_zip(&st, &files, "bill", &out).unwrap();
    assert_eq!(sum.files, 1);
    let all = st.all_blocks(&bill.id).unwrap();
    assert!(all.iter().any(|b| b.id == "n1" && !b.deleted));
    assert!(all.iter().any(|b| b.id == "extra" && b.deleted));
    assert_eq!(
        std::fs::read(files.join(&bill.id).join(fid)).unwrap(),
        b"abc"
    );
}

#[test]
fn backup_restore_keeps_task_and_calendar_blocks() {
    let dir = tempfile::tempdir().unwrap();
    let files = dir.path().join("files");
    std::fs::create_dir_all(&files).unwrap();
    let st = Storage::in_memory().unwrap();
    let bill = st.create_user("bill", "h").unwrap();
    let task_payload = json!({
        "schema": 1, "is_task": true, "status": "in_progress", "priority": 3,
        "start_at": 1_764_000_000_000i64, "due_at": 1_765_000_000_000i64, "all_day": false,
        "progress_mode": "weighted",
        "progress_items": [{"id": "p1", "title": "初稿", "weight": 3, "done": true}],
        "future_key": {"kept": true}
    });
    let cal_payload = json!({
        "role": "subscription", "start_date": "2026-11-01",
        "billing": {"cycle": "yearly", "auto_renew": true, "amount": 168}
    });
    applied(&st, &bill.id, "t1", "task", "季度汇报", task_payload.clone(), 3, None);
    applied(&st, &bill.id, "c1", "calendar", "iCloud", cal_payload.clone(), 4, None);
    let out = dir.path().join("export.zip");
    admin::export_user(&st, &files, "bill", &out).unwrap();

    applied(&st, &bill.id, "t1", "task", "改坏了", json!({}), 50, None);
    applied(&st, &bill.id, "c1", "calendar", "改坏了", json!({}), 50, None);
    backup::restore_from_zip(&st, &files, "bill", &out).unwrap();
    let all = st.all_blocks(&bill.id).unwrap();
    let t = all.iter().find(|b| b.id == "t1").unwrap();
    assert_eq!(t.kind, "task");
    assert_eq!(t.title, "季度汇报");
    assert_eq!(t.payload, task_payload);
    let c = all.iter().find(|b| b.id == "c1").unwrap();
    assert_eq!(c.kind, "calendar");
    assert_eq!(c.payload, cal_payload);
    assert!(!t.deleted && !c.deleted);
}
