//! Recycle bin (回收站) tests: soft delete, restore, purge, retention, migration, cascade.

use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use syncnotes_server::blocks::ViewedMode;
use syncnotes_server::{build_router, AppState, Storage};
use tokio_tungstenite::{connect_async, tungstenite::Message};

const DAY: i64 = 24 * 3600 * 1000;

fn up(
    st: &Storage,
    uid: &str,
    dev: &str,
    id: &str,
    kind: &str,
    parent: Option<&str>,
    ts: i64,
    del: bool,
    at: Option<Option<i64>>,
) -> syncnotes_server::blocks::Block {
    match st
        .upsert_block(
            uid,
            dev,
            id,
            kind,
            id,
            &json!({"file_id": format!("{id}-0")}),
            parent,
            ViewedMode::PerDevice,
            ts,
            del,
            at,
        )
        .unwrap()
    {
        syncnotes_server::storage::UpsertOutcome::Applied(b)
        | syncnotes_server::storage::UpsertOutcome::Stale(b) => b,
    }
}

fn user(st: &Storage) -> String {
    st.create_user("bill", "x").unwrap().id
}

#[test]
fn soft_delete_and_restore_lww() {
    let st = Storage::in_memory().unwrap();
    let u = user(&st);
    up(&st, &u, "pc", "a", "note", None, 1, false, None);
    let b = up(
        &st,
        &u,
        "phone",
        "a",
        "note",
        None,
        2,
        false,
        Some(Some(1000)),
    );
    assert_eq!(b.deleted_at, Some(1000));
    assert_eq!(b.deleted_by.as_deref(), Some("phone"));
    assert!(!b.deleted);
    // Old client (no deleted_at field) editing keeps bin state.
    let b = up(&st, &u, "old", "a", "note", None, 3, false, None);
    assert_eq!(b.deleted_at, Some(1000));
    // Stale restore loses.
    let b = up(&st, &u, "pc", "a", "note", None, 2, false, Some(None));
    assert_eq!(b.deleted_at, Some(1000));
    // Newer restore wins.
    let b = up(&st, &u, "pc", "a", "note", None, 4, false, Some(None));
    assert_eq!(b.deleted_at, None);
    assert_eq!(b.deleted_by, None);
}

#[test]
fn folder_cascade_purge_and_blob_removal() {
    let dir = tempfile::tempdir().unwrap();
    let st = Storage::in_memory().unwrap();
    let u = user(&st);
    let state = AppState::new(st.clone(), true).with_files_dir(dir.path().to_path_buf());
    up(&st, &u, "pc", "f", "folder", None, 1, false, None);
    up(&st, &u, "pc", "sub", "folder", Some("f"), 1, false, None);
    up(&st, &u, "pc", "c", "file", Some("sub"), 1, false, None);
    up(&st, &u, "pc", "other", "file", None, 1, false, None);
    // file ids "c-0" isn't hex-only; use real-looking ids
    st.upsert_block(
        &u,
        "pc",
        "c",
        "file",
        "c",
        &json!({"file_id":"abc-1"}),
        Some("sub"),
        ViewedMode::PerDevice,
        2,
        false,
        None,
    )
    .unwrap();
    std::fs::create_dir_all(dir.path().join(&u)).unwrap();
    std::fs::write(dir.path().join(&u).join("abc-1"), b"x").unwrap();
    // Trash folder: children untouched (restore brings them back with structure).
    up(&st, &u, "pc", "f", "folder", None, 3, false, Some(Some(10)));
    assert_eq!(st.get_block(&u, "c").unwrap().unwrap().deleted_at, None);
    // Blob kept while in bin.
    assert!(dir.path().join(&u).join("abc-1").exists());
    let n = syncnotes_server::trash::purge_tree(&state, &u, "f");
    assert_eq!(n, 3);
    for id in ["f", "sub", "c"] {
        assert!(st.get_block(&u, id).unwrap().unwrap().deleted, "{id}");
    }
    assert!(!st.get_block(&u, "other").unwrap().unwrap().deleted);
    assert!(!dir.path().join(&u).join("abc-1").exists());
}

#[test]
fn retention_purge() {
    let st = Storage::in_memory().unwrap();
    let u = user(&st);
    let state = AppState::new(st.clone(), true);
    let now = 100 * DAY;
    up(
        &st,
        &u,
        "pc",
        "old",
        "note",
        None,
        1,
        false,
        Some(Some(now - 31 * DAY)),
    );
    up(
        &st,
        &u,
        "pc",
        "new",
        "note",
        None,
        1,
        false,
        Some(Some(now - 2 * DAY)),
    );
    up(&st, &u, "pc", "live", "note", None, 1, false, None);
    assert_eq!(syncnotes_server::trash::purge_expired(&state, 0, now), 0);
    assert!(!st.get_block(&u, "old").unwrap().unwrap().deleted);
    assert_eq!(syncnotes_server::trash::purge_expired(&state, 30, now), 1);
    assert!(st.get_block(&u, "old").unwrap().unwrap().deleted);
    assert!(!st.get_block(&u, "new").unwrap().unwrap().deleted);
    assert!(!st.get_block(&u, "live").unwrap().unwrap().deleted);
    assert_eq!(syncnotes_server::trash::purge_expired(&state, 1, now), 1);
    assert!(st.get_block(&u, "new").unwrap().unwrap().deleted);
}

#[test]
fn migrates_old_database() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("old.db");
    {
        let c = rusqlite::Connection::open(&db).unwrap();
        c.execute_batch(
            "CREATE TABLE blocks (id TEXT NOT NULL, user_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
              payload TEXT NOT NULL, parent_id TEXT, viewed_mode TEXT NOT NULL, viewed_global INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, created_by TEXT NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL, PRIMARY KEY (user_id, id));
             INSERT INTO blocks VALUES ('b','u','note','t','{}',NULL,'global',0,1,1,'pc',0,1);",
        )
        .unwrap();
    }
    let st = Storage::open(&db).unwrap();
    let b = st.get_block("u", "b").unwrap().unwrap();
    assert_eq!(b.deleted_at, None);
    let b = up(&st, "u", "pc", "b", "note", None, 2, false, Some(Some(5)));
    assert_eq!(b.deleted_at, Some(5));
    drop(st);
    // Re-open is idempotent.
    let st = Storage::open(&db).unwrap();
    assert_eq!(st.get_block("u", "b").unwrap().unwrap().deleted_at, Some(5));
}

#[tokio::test]
async fn delete_restore_purge_sync_over_ws() {
    let dir = tempfile::tempdir().unwrap().keep();
    let state = AppState::new(Storage::in_memory().unwrap(), true).with_files_dir(dir);
    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let c = reqwest::Client::new();
    c.post(format!("http://{addr}/api/register"))
        .json(&json!({"username":"bill","password":"pw12"}))
        .send()
        .await
        .unwrap();
    let h: Value = c
        .get(format!("http://{addr}/health"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(h["protocol"], 2);
    assert_eq!(h["trash_retention_days"], 30);
    let mut ws = Vec::new();
    for dev in ["a", "b"] {
        let v: Value = c
            .post(format!("http://{addr}/api/login"))
            .json(&json!({"username":"bill","password":"pw12","device_id":dev}))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let (mut w, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
        w.send(Message::Text(
            json!({"type":"auth","token":v["token"],"device_id":dev}).to_string(),
        ))
        .await
        .unwrap();
        ws.push(w);
    }
    async fn next_block(
        w: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> Value {
        loop {
            let m = tokio::time::timeout(Duration::from_secs(5), w.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            if let Message::Text(t) = m {
                let v: Value = serde_json::from_str(&t).unwrap();
                if v["type"] == "block_update" {
                    return v["block"].clone();
                }
            }
        }
    }
    let msg = |ts: i64, at: Value, del: bool| json!({"type":"upsert_block","id":"n1","kind":"note","title":"t","payload":{},"parent_id":null,"viewed_mode":"global","client_updated_at":ts,"deleted":del,"deleted_at":at});
    let (a, b) = ws.split_at_mut(1);
    let (a, b) = (&mut a[0], &mut b[0]);
    a.send(Message::Text(msg(1, Value::Null, false).to_string()))
        .await
        .unwrap();
    next_block(b).await;
    a.send(Message::Text(msg(2, json!(99), false).to_string()))
        .await
        .unwrap();
    let v = next_block(b).await;
    assert_eq!(v["deleted_at"], 99);
    assert_eq!(v["deleted_by"], "a");
    a.send(Message::Text(msg(3, Value::Null, false).to_string()))
        .await
        .unwrap();
    assert!(next_block(b).await["deleted_at"].is_null());
    a.send(Message::Text(msg(4, json!(100), true).to_string()))
        .await
        .unwrap();
    assert_eq!(next_block(b).await["deleted"], true);
}
