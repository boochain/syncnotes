//! End-to-end tests: real server on a random port, real WebSocket clients.

use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use syncnotes_server::{build_router, AppState, Storage};
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn spawn_server() -> String {
    let dir = tempfile::tempdir().unwrap().keep();
    let state = AppState::new(Storage::in_memory().unwrap(), true).with_files_dir(dir);
    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("127.0.0.1:{}", addr.port())
}

async fn register(addr: &str, user: &str, pw: &str) -> reqwest::Response {
    reqwest::Client::new()
        .post(format!("http://{addr}/api/register"))
        .json(&json!({"username": user, "password": pw}))
        .send()
        .await
        .unwrap()
}

async fn login(addr: &str, user: &str, pw: &str, device: &str) -> Option<String> {
    let r = reqwest::Client::new()
        .post(format!("http://{addr}/api/login"))
        .json(&json!({"username": user, "password": pw, "device_id": device}))
        .send()
        .await
        .unwrap();
    if !r.status().is_success() {
        return None;
    }
    let v: Value = r.json().await.unwrap();
    Some(v["token"].as_str().unwrap().to_string())
}

async fn send(ws: &mut Ws, v: Value) {
    ws.send(Message::Text(v.to_string())).await.unwrap();
}

/// Receive next JSON text message (with timeout).
async fn recv(ws: &mut Ws) -> Value {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(5), ws.next())
            .await
            .expect("timeout waiting for message")
            .unwrap()
            .unwrap();
        if let Message::Text(t) = m {
            return serde_json::from_str(&t).unwrap();
        }
    }
}

/// Receive until a message of the given type arrives.
async fn recv_type(ws: &mut Ws, ty: &str) -> Value {
    loop {
        let v = recv(ws).await;
        if v["type"] == ty {
            return v;
        }
    }
}

/// Assert no message arrives within a short window.
async fn assert_silent(ws: &mut Ws) {
    let r = tokio::time::timeout(Duration::from_millis(300), ws.next()).await;
    assert!(r.is_err(), "expected no message, got {:?}", r);
}

async fn connect(addr: &str, token: &str, device: &str) -> Ws {
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(
        &mut ws,
        json!({"type": "auth", "token": token, "device_id": device}),
    )
    .await;
    let v = recv(&mut ws).await;
    assert_eq!(v["type"], "auth_ok", "auth failed: {v}");
    ws
}

fn upsert(id: &str, kind: &str, title: &str, payload: Value, mode: &str, ts: i64) -> Value {
    json!({
        "type": "upsert_block", "id": id, "kind": kind, "title": title,
        "payload": payload, "parent_id": null, "viewed_mode": mode,
        "client_updated_at": ts, "deleted": false
    })
}

async fn setup_user(addr: &str, user: &str) {
    assert!(register(addr, user, "pass1234").await.status().is_success());
}

#[tokio::test]
async fn health_ok() {
    let addr = spawn_server().await;
    let v: Value = reqwest::get(format!("http://{addr}/health"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(v["status"], "ok");
}

#[tokio::test]
async fn auth_flow_and_rejections() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    // duplicate
    assert_eq!(register(&addr, "bill", "pass1234").await.status(), 409);
    // bad password
    assert!(login(&addr, "bill", "wrong", "d1").await.is_none());
    // unknown user
    assert!(login(&addr, "nobody", "pass1234", "d1").await.is_none());
    // good
    let tok = login(&addr, "bill", "pass1234", "d1").await.unwrap();
    // invalid ws token
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(
        &mut ws,
        json!({"type":"auth","token":"bogus","device_id":"d1"}),
    )
    .await;
    assert_eq!(recv(&mut ws).await["type"], "auth_error");
    // unauthenticated op rejected
    send(
        &mut ws,
        upsert("x", "note", "t", json!({}), "per_device", 1),
    )
    .await;
    assert_eq!(recv(&mut ws).await["type"], "auth_error");
    // valid token works (auto-login: reusing a stored token)
    let _ws = connect(&addr, &tok, "d1").await;
}

#[tokio::test]
async fn multi_client_realtime_sync() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let t2 = login(&addr, "bill", "pass1234", "phone").await.unwrap();
    let t3 = login(&addr, "bill", "pass1234", "laptop").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    let mut b = connect(&addr, &t2, "phone").await;
    let mut c = connect(&addr, &t3, "laptop").await;

    send(
        &mut a,
        upsert(
            "m1",
            "message",
            "你好",
            json!({"text":"来自电脑"}),
            "global",
            100,
        ),
    )
    .await;
    for ws in [&mut a, &mut b, &mut c] {
        let v = recv_type(ws, "block_update").await;
        assert_eq!(v["block"]["id"], "m1");
        assert_eq!(v["block"]["payload"]["text"], "来自电脑");
        assert_eq!(v["block"]["kind"], "message");
    }

    // Edit from phone propagates to all.
    send(
        &mut b,
        upsert(
            "m1",
            "message",
            "你好",
            json!({"text":"手机修改"}),
            "global",
            200,
        ),
    )
    .await;
    for ws in [&mut a, &mut b, &mut c] {
        let v = recv_type(ws, "block_update").await;
        assert_eq!(v["block"]["payload"]["text"], "手机修改");
    }
}

#[tokio::test]
async fn users_are_isolated() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    setup_user(&addr, "eve").await;
    let tb = login(&addr, "bill", "pass1234", "d").await.unwrap();
    let te = login(&addr, "eve", "pass1234", "d").await.unwrap();
    let mut b = connect(&addr, &tb, "d").await;
    let mut e = connect(&addr, &te, "d").await;
    send(
        &mut b,
        upsert(
            "n1",
            "note",
            "secret",
            json!({"markdown":"x"}),
            "per_device",
            1,
        ),
    )
    .await;
    recv_type(&mut b, "block_update").await;
    assert_silent(&mut e).await;
    // Eve catch-up should be empty
    send(&mut e, json!({"type":"sync_since","since_seq":0})).await;
    let v = recv(&mut e).await;
    assert_eq!(v["type"], "sync_complete");
    assert_eq!(v["latest_seq"], 0);
}

#[tokio::test]
async fn viewed_global_mode_syncs_everywhere() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let t2 = login(&addr, "bill", "pass1234", "phone").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    let mut b = connect(&addr, &t2, "phone").await;

    send(
        &mut a,
        upsert("g1", "message", "g", json!({"text":"hi"}), "global", 1),
    )
    .await;
    recv_type(&mut a, "block_update").await;
    recv_type(&mut b, "block_update").await;

    send(
        &mut b,
        json!({"type":"set_viewed","block_id":"g1","viewed":true}),
    )
    .await;
    for ws in [&mut a, &mut b] {
        let v = recv_type(ws, "viewed_update").await;
        assert_eq!(v["block_id"], "g1");
        assert_eq!(v["viewed"], true);
        assert!(
            v["device_id"].is_null(),
            "global update has no device scope"
        );
    }
    // Catch-up on a new device shows viewed_global=true
    let t3 = login(&addr, "bill", "pass1234", "laptop").await.unwrap();
    let mut c = connect(&addr, &t3, "laptop").await;
    send(&mut c, json!({"type":"sync_since","since_seq":0})).await;
    let v = recv_type(&mut c, "block_update").await;
    assert_eq!(v["block"]["viewed_global"], true);
}

#[tokio::test]
async fn viewed_per_device_mode_is_independent() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let t2 = login(&addr, "bill", "pass1234", "phone").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    let mut b = connect(&addr, &t2, "phone").await;

    send(
        &mut a,
        upsert(
            "p1",
            "note",
            "n",
            json!({"markdown":"# hi"}),
            "per_device",
            1,
        ),
    )
    .await;
    recv_type(&mut a, "block_update").await;
    recv_type(&mut b, "block_update").await;

    send(
        &mut a,
        json!({"type":"set_viewed","block_id":"p1","viewed":true}),
    )
    .await;
    let v = recv_type(&mut a, "viewed_update").await;
    assert_eq!(v["device_id"], "pc");
    // Phone must NOT receive pc's per-device viewed state.
    assert_silent(&mut b).await;

    // Phone catch-up: block not viewed for phone, no viewed_update for phone.
    send(&mut b, json!({"type":"sync_since","since_seq":0})).await;
    let mut got_viewed = false;
    loop {
        let v = recv(&mut b).await;
        match v["type"].as_str().unwrap() {
            "block_update" => assert_eq!(v["block"]["viewed_global"], false),
            "viewed_update" => got_viewed = true,
            "sync_complete" => break,
            _ => {}
        }
    }
    assert!(!got_viewed);

    // PC reconnect catch-up includes its own viewed state.
    drop(a);
    let mut a2 = connect(&addr, &t1, "pc").await;
    send(&mut a2, json!({"type":"sync_since","since_seq":0})).await;
    let v = recv_type(&mut a2, "viewed_update").await;
    assert_eq!(v["block_id"], "p1");
    assert_eq!(v["viewed"], true);
}

#[tokio::test]
async fn offline_edits_replay_on_reconnect() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let t2 = login(&addr, "bill", "pass1234", "phone").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;

    // Phone is offline; PC creates two blocks.
    send(
        &mut a,
        upsert("o1", "note", "one", json!({"markdown":"1"}), "global", 10),
    )
    .await;
    let s1 = recv_type(&mut a, "block_update").await["block"]["seq"]
        .as_i64()
        .unwrap();
    send(
        &mut a,
        upsert("o2", "message", "two", json!({"text":"2"}), "global", 11),
    )
    .await;
    recv_type(&mut a, "block_update").await;

    // Phone comes online having last seen seq s1 → only o2 replayed.
    let mut b = connect(&addr, &t2, "phone").await;
    send(&mut b, json!({"type":"sync_since","since_seq":s1})).await;
    let v = recv_type(&mut b, "block_update").await;
    assert_eq!(v["block"]["id"], "o2");
    assert_eq!(recv(&mut b).await["type"], "sync_complete");

    // Phone queued offline edits (created while offline, with earlier timestamps) → replay.
    send(
        &mut b,
        upsert(
            "q1",
            "message",
            "排队1",
            json!({"text":"offline 1"}),
            "global",
            20,
        ),
    )
    .await;
    send(
        &mut b,
        upsert(
            "q2",
            "message",
            "排队2",
            json!({"text":"offline 2"}),
            "global",
            21,
        ),
    )
    .await;
    let x = recv_type(&mut a, "block_update").await;
    let y = recv_type(&mut a, "block_update").await;
    assert_eq!(x["block"]["id"], "q1");
    assert_eq!(y["block"]["id"], "q2");

    // Replaying the same queued op again is idempotent (same id, same ts → no dup block).
    send(
        &mut b,
        upsert(
            "q1",
            "message",
            "排队1",
            json!({"text":"offline 1"}),
            "global",
            20,
        ),
    )
    .await;
    recv_type(&mut a, "block_update").await;
    let t3 = login(&addr, "bill", "pass1234", "x").await.unwrap();
    let mut c = connect(&addr, &t3, "x").await;
    send(&mut c, json!({"type":"sync_since","since_seq":0})).await;
    let mut ids = vec![];
    loop {
        let v = recv(&mut c).await;
        if v["type"] == "sync_complete" {
            break;
        }
        if v["type"] == "block_update" {
            ids.push(v["block"]["id"].as_str().unwrap().to_string());
        }
    }
    ids.sort();
    assert_eq!(ids, vec!["o1", "o2", "q1", "q2"]);
}

#[tokio::test]
async fn last_writer_wins_conflict() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let t2 = login(&addr, "bill", "pass1234", "phone").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    let mut b = connect(&addr, &t2, "phone").await;

    send(
        &mut a,
        upsert(
            "c1",
            "note",
            "new",
            json!({"markdown":"newer"}),
            "global",
            500,
        ),
    )
    .await;
    recv_type(&mut a, "block_update").await;
    recv_type(&mut b, "block_update").await;

    // Phone replays an older offline edit → rejected, phone gets current winner, pc gets nothing.
    send(
        &mut b,
        upsert(
            "c1",
            "note",
            "old",
            json!({"markdown":"older"}),
            "global",
            400,
        ),
    )
    .await;
    let v = recv_type(&mut b, "block_update").await;
    assert_eq!(v["block"]["payload"]["markdown"], "newer");
    assert_silent(&mut a).await;
}

#[tokio::test]
async fn folders_and_deletes_sync() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    send(
        &mut a,
        upsert("f1", "folder", "工作", json!({}), "global", 1),
    )
    .await;
    recv_type(&mut a, "block_update").await;
    send(
        &mut a,
        json!({
            "type":"upsert_block","id":"child","kind":"file","title":"a.pdf",
            "payload":{"name":"a.pdf","size":10,"url":"http://x/a.pdf"},
            "parent_id":"f1","viewed_mode":"per_device","client_updated_at":2,"deleted":false
        }),
    )
    .await;
    let v = recv_type(&mut a, "block_update").await;
    assert_eq!(v["block"]["parent_id"], "f1");
    assert_eq!(v["block"]["kind"], "file");
    // delete (tombstone)
    send(
        &mut a,
        json!({
            "type":"upsert_block","id":"child","kind":"file","title":"a.pdf",
            "payload":{"name":"a.pdf","size":10,"url":"http://x/a.pdf"},
            "parent_id":"f1","viewed_mode":"per_device","client_updated_at":3,"deleted":true
        }),
    )
    .await;
    let v = recv_type(&mut a, "block_update").await;
    assert_eq!(v["block"]["deleted"], true);
}

#[tokio::test]
async fn unknown_block_kind_is_tolerated() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    send(
        &mut a,
        upsert(
            "u1",
            "checklist",
            "future type",
            json!({"items":[]}),
            "global",
            1,
        ),
    )
    .await;
    let v = recv_type(&mut a, "block_update").await;
    // Kind is preserved verbatim so newer clients don't lose data through this server.
    assert_eq!(v["block"]["kind"], "checklist");
    // Invalid kinds are rejected.
    send(
        &mut a,
        upsert("u2", "Bad Kind!", "x", json!({}), "global", 1),
    )
    .await;
    assert_eq!(recv(&mut a).await["type"], "error");
}

#[tokio::test]
async fn malformed_message_returns_error() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t1 = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let mut a = connect(&addr, &t1, "pc").await;
    a.send(Message::Text("not json".into())).await.unwrap();
    assert_eq!(recv(&mut a).await["type"], "error");
    send(&mut a, json!({"type":"ping"})).await;
    assert_eq!(recv(&mut a).await["type"], "pong");
}

#[tokio::test]
async fn file_upload_download_and_isolation() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    setup_user(&addr, "eve").await;
    let tb = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let te = login(&addr, "eve", "pass1234", "pc").await.unwrap();
    let c = reqwest::Client::new();
    let r: Value = c
        .put(format!("http://{addr}/api/files?name=hello.txt"))
        .bearer_auth(&tb)
        .body("你好文件")
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = r["file_id"].as_str().unwrap();
    let got = c
        .get(format!("http://{addr}/api/files/{id}?token={tb}"))
        .send()
        .await
        .unwrap();
    assert!(got.status().is_success());
    assert_eq!(got.text().await.unwrap(), "你好文件");
    // other user cannot read it
    let other = c
        .get(format!("http://{addr}/api/files/{id}"))
        .bearer_auth(&te)
        .send()
        .await
        .unwrap();
    assert_eq!(other.status(), 404);
    // no token
    let anon = c
        .put(format!("http://{addr}/api/files?name=x"))
        .body("x")
        .send()
        .await
        .unwrap();
    assert_eq!(anon.status(), 401);
    // path traversal rejected
    let bad = c
        .get(format!("http://{addr}/api/files/..%2F..%2Fetc"))
        .bearer_auth(&tb)
        .send()
        .await
        .unwrap();
    assert!(bad.status() == 400 || bad.status() == 404);
}

#[tokio::test]
async fn logout_revokes_token() {
    let addr = spawn_server().await;
    setup_user(&addr, "bill").await;
    let t = login(&addr, "bill", "pass1234", "pc").await.unwrap();
    let r = reqwest::Client::new()
        .post(format!("http://{addr}/api/logout"))
        .bearer_auth(&t)
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 204);
    let (mut ws, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
    send(&mut ws, json!({"type":"auth","token":t,"device_id":"pc"})).await;
    assert_eq!(recv(&mut ws).await["type"], "auth_error");
}

#[tokio::test]
async fn persists_across_restart() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("p.db");
    {
        let st = Storage::open(&db).unwrap();
        st.create_user("bill", &syncnotes_server::auth::hash_password("pw12"))
            .unwrap();
        let u = st.find_user("bill").unwrap().unwrap();
        st.upsert_block(
            &u.id,
            "pc",
            "b1",
            "note",
            "t",
            &json!({"markdown":"x"}),
            None,
            syncnotes_server::blocks::ViewedMode::Global,
            5,
            false,
        )
        .unwrap();
    }
    let st = Storage::open(&db).unwrap();
    let u = st.find_user("bill").unwrap().unwrap();
    let blocks = st.blocks_since(&u.id, 0).unwrap();
    assert_eq!(blocks.len(), 1);
    assert_eq!(blocks[0].kind, "note");
    assert_eq!(st.latest_seq(&u.id).unwrap(), 1);
}
