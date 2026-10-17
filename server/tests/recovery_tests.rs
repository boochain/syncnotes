//! 忘记密码 / 恢复码 / 管理员救援 tests (real HTTP server + WebSocket clients).

use std::io::Read;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use syncnotes_server::{admin, build_router, AppState, Storage};
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

struct Srv {
    addr: String,
    state: AppState,
    files: PathBuf,
}

async fn spawn_with(per_user: u32, per_ip: u32) -> Srv {
    spawn_on(
        Storage::in_memory().unwrap(),
        tempfile::tempdir().unwrap().keep(),
        per_user,
        per_ip,
    )
    .await
}

async fn spawn_on(storage: Storage, files: PathBuf, per_user: u32, per_ip: u32) -> Srv {
    let state = AppState::new(storage, true)
        .with_files_dir(files.clone())
        .with_recovery_limits(per_user, per_ip);
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

async fn spawn() -> Srv {
    spawn_with(5, 20).await
}

async fn post(addr: &str, path: &str, token: Option<&str>, body: Value) -> (u16, Value) {
    let mut r = reqwest::Client::new()
        .post(format!("http://{addr}{path}"))
        .json(&body);
    if let Some(t) = token {
        r = r.bearer_auth(t);
    }
    let r = r.send().await.unwrap();
    let st = r.status().as_u16();
    let txt = r.text().await.unwrap();
    (st, serde_json::from_str(&txt).unwrap_or(Value::String(txt)))
}

async fn register(addr: &str, u: &str, pw: &str) -> Value {
    let (st, v) = post(
        addr,
        "/api/register",
        None,
        json!({"username": u, "password": pw}),
    )
    .await;
    assert_eq!(st, 200, "{v}");
    v
}

async fn login(addr: &str, u: &str, pw: &str, dev: &str) -> (u16, Value) {
    post(
        addr,
        "/api/login",
        None,
        json!({"username": u, "password": pw, "device_id": dev, "device_name": dev}),
    )
    .await
}

async fn recover(addr: &str, u: &str, code: &str, pw: &str) -> (u16, Value) {
    post(
        addr,
        "/api/recover",
        None,
        json!({"username": u, "recovery_code": code, "new_password": pw, "device_id": "phone"}),
    )
    .await
}

async fn send(ws: &mut Ws, v: Value) {
    ws.send(Message::Text(v.to_string())).await.unwrap();
}

async fn recv(ws: &mut Ws) -> Option<Value> {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("timeout")?;
        match m {
            Ok(Message::Text(t)) => return Some(serde_json::from_str(&t).unwrap()),
            Ok(Message::Close(_)) | Err(_) => return None,
            _ => {}
        }
    }
}

async fn ws_auth(addr: &str, token: &str, dev: &str) -> (Ws, Value) {
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(
        &mut ws,
        json!({"type": "auth", "token": token, "device_id": dev}),
    )
    .await;
    let v = recv(&mut ws).await.unwrap();
    (ws, v)
}

async fn connect(addr: &str, token: &str, dev: &str) -> Ws {
    let (ws, v) = ws_auth(addr, token, dev).await;
    assert_eq!(v["type"], "auth_ok", "{v}");
    ws
}

async fn upload(addr: &str, token: &str, name: &str, data: &[u8]) -> String {
    let r = reqwest::Client::new()
        .put(format!("http://{addr}/api/files?name={name}"))
        .bearer_auth(token)
        .body(data.to_vec())
        .send()
        .await
        .unwrap();
    assert!(r.status().is_success());
    let v: Value = r.json().await.unwrap();
    v["file_id"].as_str().unwrap().to_string()
}

async fn download(addr: &str, token: &str, id: &str) -> Option<Vec<u8>> {
    let r = reqwest::Client::new()
        .get(format!("http://{addr}/api/files/{id}"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap();
    if !r.status().is_success() {
        return None;
    }
    Some(r.bytes().await.unwrap().to_vec())
}

#[allow(clippy::too_many_arguments)]
fn upsert(
    id: &str,
    kind: &str,
    title: &str,
    payload: Value,
    parent: Option<&str>,
    mode: &str,
    ts: i64,
    deleted_at: Option<i64>,
) -> Value {
    json!({
        "type": "upsert_block", "id": id, "kind": kind, "title": title,
        "payload": payload, "parent_id": parent, "viewed_mode": mode,
        "client_updated_at": ts, "deleted": false, "deleted_at": deleted_at
    })
}

/// Full sync of a fresh connection: (blocks by id, viewed per block for this device).
async fn full_sync(
    ws: &mut Ws,
) -> (
    std::collections::HashMap<String, Value>,
    std::collections::HashMap<String, bool>,
) {
    send(ws, json!({"type": "sync_since", "since_seq": 0})).await;
    let mut blocks = std::collections::HashMap::new();
    let mut views = std::collections::HashMap::new();
    loop {
        let v = recv(ws).await.unwrap();
        match v["type"].as_str().unwrap() {
            "block_update" => {
                blocks.insert(
                    v["block"]["id"].as_str().unwrap().to_string(),
                    v["block"].clone(),
                );
            }
            "viewed_update" => {
                views.insert(
                    v["block_id"].as_str().unwrap().to_string(),
                    v["viewed"].as_bool().unwrap(),
                );
            }
            "sync_complete" => break,
            _ => {}
        }
    }
    (blocks, views)
}

// ---------------------------------------------------------------- recovery code

#[tokio::test]
async fn register_returns_code_and_recover_works() {
    let s = spawn().await;
    let v = register(&s.addr, "bill", "old-pass").await;
    let code = v["recovery_code"].as_str().unwrap().to_string();
    assert!(v["has_recovery_code"].as_bool().unwrap());
    assert_eq!(code.len(), 23);
    // Only a hash is stored.
    let row = s.state.storage.find_user("bill").unwrap().unwrap();
    let h = row.recovery_hash.unwrap();
    assert!(h.starts_with("$argon2") && !h.contains(&code));

    // Lowercase / without dashes is accepted.
    let (st, r) = recover(
        &s.addr,
        "bill",
        &code.to_lowercase().replace('-', ""),
        "new-pass",
    )
    .await;
    assert_eq!(st, 200, "{r}");
    let new_code = r["recovery_code"].as_str().unwrap();
    assert_ne!(new_code, code);
    assert!(r["token"].as_str().unwrap().len() == 64);
    assert_eq!(login(&s.addr, "bill", "old-pass", "pc").await.0, 401);
    assert_eq!(login(&s.addr, "bill", "new-pass", "pc").await.0, 200);
}

#[tokio::test]
async fn wrong_code_and_unknown_user_rejected_uniformly() {
    let s = spawn().await;
    register(&s.addr, "bill", "old-pass").await;
    let (st, a) = recover(&s.addr, "bill", "AAAAA-AAAAA-AAAAA-AAAAA", "new-pass").await;
    let (st2, b) = recover(&s.addr, "nobody", "AAAAA-AAAAA-AAAAA-AAAAA", "new-pass").await;
    assert_eq!((st, st2), (401, 401));
    assert_eq!(a, b, "same message for unknown user (no enumeration)");
    assert_eq!(login(&s.addr, "bill", "old-pass", "pc").await.0, 200);
}

#[tokio::test]
async fn code_is_one_time() {
    let s = spawn().await;
    let code = register(&s.addr, "bill", "old-pass").await["recovery_code"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(recover(&s.addr, "bill", &code, "new-pass").await.0, 200);
    let (st, _) = recover(&s.addr, "bill", &code, "evil-pass").await;
    assert_eq!(st, 401, "reused code must be rejected");
    assert_eq!(login(&s.addr, "bill", "new-pass", "pc").await.0, 200);
}

#[tokio::test]
async fn rate_limited_per_user() {
    let s = spawn_with(3, 100).await;
    let code = register(&s.addr, "bill", "old-pass").await["recovery_code"]
        .as_str()
        .unwrap()
        .to_string();
    for _ in 0..3 {
        assert_eq!(
            recover(&s.addr, "bill", "AAAAA-AAAAA-AAAAA-AAAAA", "x-pass")
                .await
                .0,
            401
        );
    }
    // Even the correct code is refused while locked.
    let (st, v) = recover(&s.addr, "bill", &code, "new-pass").await;
    assert_eq!(st, 429, "{v}");
    assert_eq!(login(&s.addr, "bill", "old-pass", "pc").await.0, 200);
}

#[tokio::test]
async fn rate_limited_per_ip() {
    let s = spawn_with(100, 4).await;
    register(&s.addr, "bill", "old-pass").await;
    for i in 0..4 {
        recover(
            &s.addr,
            &format!("u{i}"),
            "AAAAA-AAAAA-AAAAA-AAAAA",
            "x-pass",
        )
        .await;
    }
    assert_eq!(
        recover(&s.addr, "bill", "AAAAA-AAAAA-AAAAA-AAAAA", "x-pass")
            .await
            .0,
        429
    );
}

#[tokio::test]
async fn recovery_invalidates_all_tokens_and_live_sockets() {
    let s = spawn().await;
    let code = register(&s.addr, "bill", "old-pass").await["recovery_code"]
        .as_str()
        .unwrap()
        .to_string();
    let t_pc = login(&s.addr, "bill", "old-pass", "pc").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let mut live = connect(&s.addr, &t_pc, "pc").await;
    let (st, r) = recover(&s.addr, "bill", &code, "new-pass").await;
    assert_eq!(st, 200);
    // Live socket is told and closed.
    let v = recv(&mut live).await.unwrap();
    assert_eq!(v["type"], "auth_error");
    assert!(recv(&mut live).await.is_none(), "socket should close");
    // Old token can't auth or download.
    let (_, v) = ws_auth(&s.addr, &t_pc, "pc").await;
    assert_eq!(v["type"], "auth_error");
    assert_eq!(
        s.state
            .storage
            .token_count(&s.state.storage.find_user("bill").unwrap().unwrap().id)
            .unwrap(),
        1
    );
    // The newly issued token works.
    connect(&s.addr, r["token"].as_str().unwrap(), "phone").await;
}

#[tokio::test]
async fn legacy_user_gets_prompt_and_can_generate() {
    let s = spawn().await;
    // Simulate a pre-recovery account (no recovery_hash).
    let hash = syncnotes_server::auth::hash_password("old-pass");
    s.state.storage.create_user("legacy", &hash).unwrap();
    let (st, v) = login(&s.addr, "legacy", "old-pass", "pc").await;
    assert_eq!(st, 200);
    assert_eq!(v["has_recovery_code"], false);
    assert!(v.get("recovery_code").is_none());
    let tok = v["token"].as_str().unwrap();
    // Recover without a code is impossible.
    assert_eq!(
        recover(&s.addr, "legacy", "AAAAA-AAAAA-AAAAA-AAAAA", "n-pass")
            .await
            .0,
        401
    );
    // Generating requires the current password.
    let (st, _) = post(
        &s.addr,
        "/api/recovery-code",
        Some(tok),
        json!({"password": "nope"}),
    )
    .await;
    assert_eq!(st, 401);
    let (st, _) = post(
        &s.addr,
        "/api/recovery-code",
        None,
        json!({"password": "old-pass"}),
    )
    .await;
    assert_eq!(st, 401);
    let (st, g) = post(
        &s.addr,
        "/api/recovery-code",
        Some(tok),
        json!({"password": "old-pass"}),
    )
    .await;
    assert_eq!(st, 200);
    let code = g["recovery_code"].as_str().unwrap();
    assert_eq!(
        login(&s.addr, "legacy", "old-pass", "pc").await.1["has_recovery_code"],
        true
    );
    // Regenerating replaces the old code.
    let (_, g2) = post(
        &s.addr,
        "/api/recovery-code",
        Some(tok),
        json!({"password": "old-pass"}),
    )
    .await;
    assert_eq!(recover(&s.addr, "legacy", code, "n-pass").await.0, 401);
    assert_eq!(
        recover(
            &s.addr,
            "legacy",
            g2["recovery_code"].as_str().unwrap(),
            "n-pass"
        )
        .await
        .0,
        200
    );
}

#[tokio::test]
async fn change_password_keeps_current_session_only() {
    let s = spawn().await;
    register(&s.addr, "bill", "old-pass").await;
    let a = login(&s.addr, "bill", "old-pass", "pc").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let b = login(&s.addr, "bill", "old-pass", "phone").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let (st, _) = post(
        &s.addr,
        "/api/change-password",
        Some(&a),
        json!({"old_password": "bad", "new_password": "n-pass"}),
    )
    .await;
    assert_eq!(st, 401);
    let (st, _) = post(
        &s.addr,
        "/api/change-password",
        Some(&a),
        json!({"old_password": "old-pass", "new_password": "n-pass"}),
    )
    .await;
    assert_eq!(st, 204);
    connect(&s.addr, &a, "pc").await;
    assert_eq!(ws_auth(&s.addr, &b, "phone").await.1["type"], "auth_error");
}

// ---------------------------------------------------------------- admin rescue

#[tokio::test]
async fn admin_reset_forces_change_and_blocks_sync_until_changed() {
    let s = spawn().await;
    register(&s.addr, "bill", "old-pass").await;
    let old = login(&s.addr, "bill", "old-pass", "pc").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let r = admin::reset_password(&s.state.storage, "bill", None, true).unwrap();
    assert!(r.generated && r.password.len() >= 12);
    assert_eq!(r.revoked_tokens, 2);
    assert_eq!(ws_auth(&s.addr, &old, "pc").await.1["type"], "auth_error");
    let (st, v) = login(&s.addr, "bill", &r.password, "pc").await;
    assert_eq!(st, 200);
    assert_eq!(v["must_change_password"], true);
    let t = v["token"].as_str().unwrap();
    let (_, a) = ws_auth(&s.addr, t, "pc").await;
    assert_eq!(
        a["type"], "auth_error",
        "sync blocked until temp password changed"
    );
    let (st, _) = post(
        &s.addr,
        "/api/change-password",
        Some(t),
        json!({"old_password": r.password, "new_password": "mine-now"}),
    )
    .await;
    assert_eq!(st, 204);
    connect(&s.addr, t, "pc").await;
    assert_eq!(
        login(&s.addr, "bill", "mine-now", "pc").await.1["must_change_password"],
        false
    );
    assert!(admin::reset_password(&s.state.storage, "ghost", None, true).is_err());
    assert!(admin::reset_password(&s.state.storage, "bill", Some("x".into()), true).is_err());
}

#[tokio::test]
async fn admin_list_users() {
    let s = spawn().await;
    register(&s.addr, "bill", "old-pass").await;
    s.state.storage.create_user("legacy", "x").unwrap();
    let u = admin::list_users(&s.state.storage).unwrap();
    assert_eq!(u.len(), 2);
    assert!(u
        .iter()
        .any(|x| x.username == "bill" && x.has_recovery_code));
    assert!(u
        .iter()
        .any(|x| x.username == "legacy" && !x.has_recovery_code));
    let txt = admin::format_users(&u);
    assert!(txt.contains("bill") && txt.contains("legacy"));
}

/// Builds a rich account on two devices; returns (token_pc, file ids).
async fn seed_rich_account(s: &Srv) -> (String, Vec<(String, Vec<u8>)>) {
    register(&s.addr, "bill", "old-pass").await;
    let t_pc = login(&s.addr, "bill", "old-pass", "pc").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let t_ph = login(&s.addr, "bill", "old-pass", "phone").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let mut pc = connect(&s.addr, &t_pc, "pc").await;
    let mut ph = connect(&s.addr, &t_ph, "phone").await;
    let f1: Vec<u8> = (0..5000u32).map(|i| (i % 251) as u8).collect();
    let f2 = b"trash attachment".to_vec();
    let id1 = upload(&s.addr, &t_pc, "report.pdf", &f1).await;
    let id2 = upload(&s.addr, &t_ph, "old.txt", &f2).await;
    let msgs = vec![
        (
            0,
            upsert(
                "folder1",
                "folder",
                "工作",
                json!({}),
                None,
                "global",
                1,
                None,
            ),
        ),
        (
            0,
            upsert(
                "page1",
                "page",
                "周报",
                json!({"icon": "📝"}),
                Some("folder1"),
                "global",
                2,
                None,
            ),
        ),
        (
            0,
            upsert(
                "p1b1",
                "doc",
                "",
                json!({"type": "h1", "text": "本周进展", "order": 1}),
                Some("page1"),
                "global",
                3,
                None,
            ),
        ),
        (
            0,
            upsert(
                "p1b2",
                "doc",
                "",
                json!({"type": "todo", "text": "写测试", "checked": true, "order": 2}),
                Some("page1"),
                "global",
                4,
                None,
            ),
        ),
        (
            0,
            upsert(
                "p1b2c",
                "doc",
                "",
                json!({"type": "bullet", "text": "嵌套子块", "order": 1}),
                Some("p1b2"),
                "global",
                5,
                None,
            ),
        ),
        (
            0,
            upsert(
                "file1",
                "file",
                "report.pdf",
                json!({"file_id": id1, "name": "report.pdf", "size": 5000, "order": 3}),
                Some("page1"),
                "global",
                6,
                None,
            ),
        ),
        (
            1,
            upsert(
                "msg1",
                "message",
                "",
                json!({"text": "手机上的消息"}),
                None,
                "per_device",
                7,
                None,
            ),
        ),
        (
            1,
            upsert(
                "note1",
                "note",
                "随手记",
                json!({"markdown": "**加粗** 内容"}),
                None,
                "global",
                8,
                None,
            ),
        ),
        (
            1,
            upsert(
                "trash1",
                "note",
                "旧笔记",
                json!({"markdown": "回收站里的内容"}),
                None,
                "global",
                9,
                Some(1_700_000_000_000),
            ),
        ),
        (
            1,
            upsert(
                "trashfile",
                "file",
                "old.txt",
                json!({"file_id": id2, "name": "old.txt", "size": 16}),
                None,
                "global",
                10,
                Some(1_700_000_000_000),
            ),
        ),
    ];
    for (which, m) in msgs {
        let ws = if which == 0 { &mut pc } else { &mut ph };
        let id = m["id"].clone();
        send(ws, m).await;
        loop {
            let v = recv(ws).await.unwrap();
            if v["type"] == "block_update" && v["block"]["id"] == id {
                break;
            }
        }
    }
    // Read state: global on note1, per-device on msg1 for phone only.
    send(
        &mut pc,
        json!({"type": "set_viewed", "block_id": "note1", "viewed": true}),
    )
    .await;
    loop {
        let v = recv(&mut pc).await.unwrap();
        if v["type"] == "viewed_update" && v["block_id"] == "note1" {
            break;
        }
    }
    send(
        &mut ph,
        json!({"type": "set_viewed", "block_id": "msg1", "viewed": true}),
    )
    .await;
    loop {
        let v = recv(&mut ph).await.unwrap();
        if v["type"] == "viewed_update" && v["block_id"] == "msg1" {
            break;
        }
    }
    (t_pc, vec![(id1, f1), (id2, f2)])
}

#[tokio::test]
async fn admin_reset_preserves_all_data_and_syncs_to_fresh_device() {
    let s = spawn().await;
    let (_old, files) = seed_rich_account(&s).await;
    let uid_before = s.state.storage.find_user("bill").unwrap().unwrap().id;
    let before = s.state.storage.all_blocks(&uid_before).unwrap();
    let views_before = s.state.storage.all_device_views(&uid_before).unwrap();

    let r =
        admin::reset_password(&s.state.storage, "bill", Some("temp-1234".into()), true).unwrap();
    assert!(!r.generated);
    let v = login(&s.addr, "bill", "temp-1234", "laptop").await.1;
    assert_eq!(v["user_id"], uid_before.as_str(), "user id unchanged");
    let t = v["token"].as_str().unwrap();
    post(
        &s.addr,
        "/api/change-password",
        Some(t),
        json!({"old_password": "temp-1234", "new_password": "fresh-pass"}),
    )
    .await;

    let after = s.state.storage.all_blocks(&uid_before).unwrap();
    assert_eq!(
        serde_json::to_value(&before).unwrap(),
        serde_json::to_value(&after).unwrap(),
        "blocks byte-identical"
    );
    assert_eq!(
        views_before,
        s.state.storage.all_device_views(&uid_before).unwrap()
    );

    // Fresh device sees everything incl. trash + nested + read state.
    let mut ws = connect(&s.addr, t, "laptop").await;
    let (blocks, _) = full_sync(&mut ws).await;
    for id in [
        "folder1",
        "page1",
        "p1b1",
        "p1b2",
        "p1b2c",
        "file1",
        "msg1",
        "note1",
        "trash1",
        "trashfile",
    ] {
        assert!(blocks.contains_key(id), "missing {id}");
    }
    assert_eq!(blocks["p1b2c"]["parent_id"], "p1b2");
    assert_eq!(blocks["trash1"]["deleted_at"], 1_700_000_000_000i64);
    assert_eq!(blocks["note1"]["viewed_global"], true);
    for (id, data) in &files {
        assert_eq!(
            download(&s.addr, t, id).await.as_deref(),
            Some(data.as_slice())
        );
    }
    // Per-device read state of the phone survives (re-login as phone).
    let tp = login(&s.addr, "bill", "fresh-pass", "phone").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let mut ph = connect(&s.addr, &tp, "phone").await;
    let (_, views) = full_sync(&mut ph).await;
    assert_eq!(views.get("msg1"), Some(&true));
}

#[tokio::test]
async fn admin_export_contains_everything() {
    let s = spawn().await;
    let (_t, files) = seed_rich_account(&s).await;
    let out = tempfile::tempdir().unwrap().keep().join("sub/bill.zip");
    let sum = admin::export_user(&s.state.storage, &s.files, "bill", &out).unwrap();
    assert_eq!(sum.blocks, 10);
    assert_eq!(sum.trashed, 2);
    assert_eq!(sum.files, 2);
    assert_eq!(sum.missing_files, 0);
    let mut z = zip::ZipArchive::new(std::fs::File::open(&out).unwrap()).unwrap();
    let names: Vec<String> = z.file_names().map(str::to_string).collect();
    let read = |z: &mut zip::ZipArchive<std::fs::File>, n: &str| {
        let mut s = Vec::new();
        z.by_name(n).unwrap().read_to_end(&mut s).unwrap();
        s
    };
    let blocks: Vec<Value> = serde_json::from_slice(&read(&mut z, "blocks.json")).unwrap();
    assert_eq!(blocks.len(), 10);
    assert!(blocks
        .iter()
        .any(|b| b["id"] == "trash1" && b["deleted_at"].is_number()));
    let manifest: Value = serde_json::from_slice(&read(&mut z, "manifest.json")).unwrap();
    assert_eq!(manifest["username"], "bill");
    let views: Vec<Value> = serde_json::from_slice(&read(&mut z, "device_views.json")).unwrap();
    assert!(views
        .iter()
        .any(|v| v["block_id"] == "msg1" && v["device_id"] == "phone"));
    let md = String::from_utf8(read(&mut z, "markdown/工作.md")).unwrap();
    assert!(md.contains("# 工作"), "{md}");
    assert!(
        md.contains("本周进展") && md.contains("- [x] 写测试") && md.contains("嵌套子块"),
        "{md}"
    );
    assert!(md.contains("report.pdf](../files/"), "{md}");
    assert!(
        names.iter().any(|n| n == "markdown/回收站/旧笔记.md"),
        "{names:?}"
    );
    assert!(names.iter().any(|n| n == "markdown/随手记.md"));
    let f1 = names
        .iter()
        .find(|n| n.starts_with("files/") && n.ends_with("report.pdf"))
        .unwrap()
        .clone();
    assert_eq!(read(&mut z, &f1), files[0].1);
    assert!(names
        .iter()
        .any(|n| n.starts_with("files/") && n.ends_with("old.txt")));
    assert!(admin::export_user(&s.state.storage, &s.files, "ghost", &out).is_err());
}

#[tokio::test]
async fn admin_backup_is_consistent_copy() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("a.db");
    let st = Storage::open(&db).unwrap();
    st.create_user("bill", "h").unwrap();
    let out = dir.path().join("b.db");
    admin::backup(&st, &out).unwrap();
    let copy = Storage::open(&out).unwrap();
    assert!(copy.find_user("bill").unwrap().is_some());
    assert!(admin::backup(&st, &out).is_err(), "refuse to overwrite");
}

#[test]
fn legacy_database_migrates_without_touching_data() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("old.db");
    {
        let c = rusqlite::Connection::open(&db).unwrap();
        c.execute_batch(
            "CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, created_at INTEGER NOT NULL);
             INSERT INTO users VALUES ('u1', 'old', 'h', 1);",
        )
        .unwrap();
    }
    let st = Storage::open(&db).unwrap();
    let u = st.find_user("old").unwrap().unwrap();
    assert_eq!(u.id, "u1");
    assert!(u.recovery_hash.is_none() && !u.must_change_password);
}

// ---------------------------------------------------------------- script (PATH shims)

fn repo_scripts() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../scripts")
}

/// Temp env dir + shim bin dir. `server` = path the `syncnotes-server` shim points at.
fn script_env(
    db: &std::path::Path,
    files: &std::path::Path,
    server: &str,
) -> (tempfile::TempDir, String) {
    let t = tempfile::tempdir().unwrap();
    let env_dir = t.path().join("etc");
    let bin = t.path().join("bin");
    std::fs::create_dir_all(&env_dir).unwrap();
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(
        env_dir.join("syncnotes.env"),
        format!(
            "SYNCNOTES_INSTALL_DIR={}\nSYNCNOTES_DB={}\nSYNCNOTES_FILES={}\n",
            t.path().join("not-installed").display(),
            db.display(),
            files.display()
        ),
    )
    .unwrap();
    let w = |name: &str, body: &str| {
        let p = bin.join(name);
        std::fs::write(&p, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    // Pretend to be root so need_root passes without sudo.
    w(
        "id",
        "#!/bin/sh\n[ \"$1\" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id \"$@\"\n",
    );
    w("syncnotes-server", &format!("#!/bin/sh\n{server}\n"));
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    (t, path)
}

fn run_script(t: &tempfile::TempDir, path: &str, script: &str, args: &[&str]) -> (bool, String) {
    let o = std::process::Command::new("bash")
        .arg(repo_scripts().join(script))
        .args(args)
        .current_dir(t.path())
        .env("PATH", path)
        .env("SYNCNOTES_ENV_DIR", t.path().join("etc"))
        .env("SYNCNOTES_SVC_USER", "root")
        .env_remove("SUDO_USER")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let out = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    (o.status.success(), out)
}

#[test]
fn script_passes_env_paths_and_backs_up_before_reset() {
    let d = tempfile::tempdir().unwrap();
    let db = d.path().join("data/s.db");
    std::fs::create_dir_all(db.parent().unwrap()).unwrap();
    std::fs::write(&db, b"").unwrap();
    let log = d.path().join("calls.log");
    let (t, path) = script_env(
        &db,
        &d.path().join("files"),
        &format!("echo \"$*\" >> {}; exit 0", log.display()),
    );
    let (ok, out) = run_script(
        &t,
        &path,
        "syncnotes-server.sh",
        &["-y", "reset-password", "bill"],
    );
    assert!(ok, "{out}");
    let calls = std::fs::read_to_string(&log).unwrap();
    let lines: Vec<&str> = calls.lines().collect();
    let files = d.path().join("files");
    assert_eq!(lines[0], "admin --help");
    assert!(
        lines.iter().any(
            |l| l.starts_with("admin backup ") && l.contains(&format!("--db {}", db.display()))
        ),
        "{calls}"
    );
    let reset = lines
        .iter()
        .position(|l| l.starts_with("admin reset-password bill"))
        .expect(&calls);
    let backup = lines
        .iter()
        .position(|l| l.starts_with("admin backup"))
        .unwrap();
    assert!(backup < reset, "backup before reset: {calls}");
    assert!(
        lines[reset].ends_with(&format!(
            "--db {} --files-dir {}",
            db.display(),
            files.display()
        )),
        "{calls}"
    );

    std::fs::remove_file(&log).unwrap();
    let (ok, out) = run_script(&t, &path, "syncnotes-rescue.sh", &["export", "bill"]);
    // Shim doesn't write the zip, so mv fails — but the command line must be right.
    assert!(!ok, "{out}");
    let calls = std::fs::read_to_string(&log).unwrap();
    assert!(
        calls.contains("admin export bill ") && calls.contains("/export.zip --db"),
        "{calls}"
    );

    let (ok, out) = run_script(&t, &path, "syncnotes-rescue.sh", &["reset", "bad/name"]);
    assert!(!ok && out.contains("用户名无效"), "{out}");
    let (ok, out) = run_script(&t, &path, "syncnotes-rescue.sh", &["list-users"]);
    assert!(ok, "{out}");
}

#[test]
fn script_rejects_old_binary_and_missing_db() {
    let d = tempfile::tempdir().unwrap();
    let db = d.path().join("s.db");
    let (t, path) = script_env(
        &db,
        &d.path().join("f"),
        "[ \"$1\" = admin ] && exit 2; exit 0",
    );
    std::fs::write(&db, b"").unwrap();
    let (ok, out) = run_script(&t, &path, "syncnotes-rescue.sh", &["list-users"]);
    assert!(!ok && out.contains("版本过旧"), "{out}");
    std::fs::remove_file(&db).unwrap();
    let (t, path) = script_env(&db, &d.path().join("f"), "exit 0");
    let (ok, out) = run_script(&t, &path, "syncnotes-rescue.sh", &["-y", "reset", "bill"]);
    assert!(!ok && out.contains("数据库不存在"), "{out}");
}

/// User requirement: after a rescue reset the user still has ALL old data.
/// Real binary + running server on the same WAL database, reset via syncnotes-rescue.sh.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn e2e_rescue_script_reset_keeps_all_data() {
    let d = tempfile::tempdir().unwrap();
    let db = d.path().join("syncnotes.db");
    let files = d.path().join("files");
    std::fs::create_dir_all(&files).unwrap();
    let s = spawn_on(Storage::open(&db).unwrap(), files.clone(), 5, 20).await;
    let (old_pc, blobs) = seed_rich_account(&s).await;
    let uid = s.state.storage.find_user("bill").unwrap().unwrap().id;
    let before = serde_json::to_value(s.state.storage.all_blocks(&uid).unwrap()).unwrap();
    let views_before = s.state.storage.all_device_views(&uid).unwrap();
    let mut stale = connect(&s.addr, &old_pc, "pc").await;

    let bin = env!("CARGO_BIN_EXE_syncnotes-server");
    let (t, path) = script_env(&db, &files, &format!("exec {bin} \"$@\""));
    let (ok, out) = tokio::task::spawn_blocking({
        let path = path.clone();
        move || {
            let r = run_script(&t, &path, "syncnotes-rescue.sh", &["-y", "reset", "bill"]);
            drop(t);
            r
        }
    })
    .await
    .unwrap();
    assert!(ok, "{out}");
    assert!(out.contains("已备份数据库"), "{out}");
    let temp = out
        .lines()
        .find_map(|l| l.strip_prefix("临时密码: "))
        .unwrap_or_else(|| panic!("{out}"))
        .trim()
        .to_string();

    // The old session (other process revoked it) is closed by the periodic re-check.
    let closed = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match stale.next().await {
                None | Some(Err(_)) | Some(Ok(Message::Close(_))) => break,
                _ => {}
            }
        }
    })
    .await;
    assert!(closed.is_ok(), "stale socket still open");
    assert_eq!(login(&s.addr, "bill", "old-pass", "pc").await.0, 401);

    // Default (temporary) password → forced change.
    let (st, v) = login(&s.addr, "bill", &temp, "pc").await;
    assert_eq!(st, 200);
    assert_eq!(v["must_change_password"], true);
    assert_eq!(v["user_id"], uid.as_str());
    let tok = v["token"].as_str().unwrap().to_string();
    assert_eq!(ws_auth(&s.addr, &tok, "pc").await.1["type"], "auth_error");
    let (st, _) = post(
        &s.addr,
        "/api/change-password",
        Some(&tok),
        json!({"old_password": temp, "new_password": "brand-new"}),
    )
    .await;
    assert_eq!(st, 204);

    // Nothing changed in the data.
    assert_eq!(
        before,
        serde_json::to_value(s.state.storage.all_blocks(&uid).unwrap()).unwrap()
    );
    assert_eq!(
        views_before,
        s.state.storage.all_device_views(&uid).unwrap()
    );

    // Old device "pc" re-logs in and replays an offline edit made before the reset.
    let mut pc = connect(&s.addr, &tok, "pc").await;
    send(
        &mut pc,
        upsert(
            "note1",
            "note",
            "随手记",
            json!({"markdown": "离线时写的修改"}),
            None,
            "global",
            100,
            None,
        ),
    )
    .await;
    loop {
        let v = recv(&mut pc).await.unwrap();
        if v["type"] == "block_update" && v["block"]["id"] == "note1" {
            assert_eq!(v["block"]["payload"]["markdown"], "离线时写的修改");
            break;
        }
    }

    // Fresh device gets everything.
    let tf = login(&s.addr, "bill", "brand-new", "fresh").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let mut fresh = connect(&s.addr, &tf, "fresh").await;
    let (blocks, _) = full_sync(&mut fresh).await;
    assert_eq!(blocks.len(), 10);
    assert_eq!(blocks["p1b2c"]["parent_id"], "p1b2");
    assert_eq!(blocks["page1"]["parent_id"], "folder1");
    assert!(
        blocks["trash1"]["deleted_at"].is_number() && blocks["trashfile"]["deleted_at"].is_number()
    );
    assert_eq!(blocks["note1"]["payload"]["markdown"], "离线时写的修改");
    for (id, data) in &blobs {
        assert_eq!(
            download(&s.addr, &tf, id).await.as_deref(),
            Some(data.as_slice())
        );
    }
    let tp = login(&s.addr, "bill", "brand-new", "phone").await.1["token"]
        .as_str()
        .unwrap()
        .to_string();
    let mut ph = connect(&s.addr, &tp, "phone").await;
    assert_eq!(full_sync(&mut ph).await.1.get("msg1"), Some(&true));

    // Export via the script while the server keeps running.
    let (t2, path2) = script_env(&db, &files, &format!("exec {bin} \"$@\""));
    let out_zip = d.path().join("bill.zip");
    let oz = out_zip.to_string_lossy().to_string();
    let (ok, out) = tokio::task::spawn_blocking(move || {
        run_script(&t2, &path2, "syncnotes-rescue.sh", &["export", "bill", &oz])
    })
    .await
    .unwrap();
    assert!(ok, "{out}");
    let z = zip::ZipArchive::new(std::fs::File::open(&out_zip).unwrap()).unwrap();
    assert!(z.file_names().any(|n| n == "markdown/回收站/旧笔记.md"));
    assert!(z.file_names().filter(|n| n.starts_with("files/")).count() == 2);
}
