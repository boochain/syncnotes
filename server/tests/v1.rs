use std::time::Duration;

use futures::StreamExt;
use syncnotes_server::{router, AppState};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

async fn boot() -> String {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.keep();
    let state = AppState::open(&path.join("t.db"), &path.join("files"), true).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router(state)).await.unwrap();
    });
    format!("http://{addr}")
}

#[tokio::test]
async fn server_fingerprint_stays_with_the_database() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.keep();
    let db = path.join("t.db");
    let files = path.join("files");
    let first = AppState::open(&db, &files, true).unwrap();
    let id = first.server_id().to_string();
    drop(first);
    let second = AppState::open(&db, &files, true).unwrap();
    assert_eq!(second.server_id(), id);
    assert!(!id.is_empty());
}

#[tokio::test]
async fn register_login_and_notes_roundtrip() {
    let base = boot().await;
    let client = reqwest::Client::new();
    let reg = client
        .post(format!("{base}/v1/register"))
        .json(&serde_json::json!({"username": "bill", "password": "secret1"}))
        .send()
        .await
        .unwrap();
    assert_eq!(reg.status(), 200);
    let session: serde_json::Value = reg.json().await.unwrap();
    let token = session["token"].as_str().unwrap();

    let bad = client
        .post(format!("{base}/v1/login"))
        .json(&serde_json::json!({"username": "bill", "password": "nope"}))
        .send()
        .await
        .unwrap();
    assert_eq!(bad.status(), 401);

    let put = client
        .put(format!("{base}/v1/notes/note1"))
        .bearer_auth(token)
        .json(&serde_json::json!({"updated_at": 10, "nonce": "bg==", "ciphertext": "aabb"}))
        .send()
        .await
        .unwrap();
    assert_eq!(put.status(), 200);

    let older = client
        .put(format!("{base}/v1/notes/note1"))
        .bearer_auth(token)
        .json(&serde_json::json!({"updated_at": 9, "nonce": "bg==", "ciphertext": "old"}))
        .send()
        .await
        .unwrap();
    assert_eq!(older.status(), 409);

    let list = client.get(format!("{base}/v1/notes")).bearer_auth(token).send().await.unwrap();
    let notes: serde_json::Value = list.json().await.unwrap();
    assert_eq!(notes[0]["ciphertext"], "aabb");
}

#[tokio::test]
async fn password_change_and_share_roundtrip() {
    let base = boot().await;
    let client = reqwest::Client::new();
    let reg = client
        .post(format!("{base}/v1/register"))
        .json(&serde_json::json!({"username": "cara", "password": "secret1"}))
        .send()
        .await
        .unwrap();
    let session: serde_json::Value = reg.json().await.unwrap();
    let token = session["token"].as_str().unwrap();

    let bad = client
        .post(format!("{base}/v1/password"))
        .bearer_auth(token)
        .json(&serde_json::json!({"password": "nope", "new_password": "secret2"}))
        .send()
        .await
        .unwrap();
    assert_eq!(bad.status(), 401);

    let ok = client
        .post(format!("{base}/v1/password"))
        .bearer_auth(token)
        .json(&serde_json::json!({"password": "secret1", "new_password": "secret2"}))
        .send()
        .await
        .unwrap();
    assert_eq!(ok.status(), 200);

    let again = client
        .post(format!("{base}/v1/login"))
        .json(&serde_json::json!({"username": "cara", "password": "secret2"}))
        .send()
        .await
        .unwrap();
    assert_eq!(again.status(), 200);

    let share = client
        .post(format!("{base}/v1/shares"))
        .bearer_auth(token)
        .json(&serde_json::json!({"id": "11111111-1111-1111-1111-111111111111", "nonce": "bg==", "ciphertext": "aabb"}))
        .send()
        .await
        .unwrap();
    assert_eq!(share.status(), 200);

    let got = client
        .get(format!("{base}/v1/shares/11111111-1111-1111-1111-111111111111"))
        .send()
        .await
        .unwrap();
    assert_eq!(got.status(), 200);
    let body: serde_json::Value = got.json().await.unwrap();
    assert_eq!(body["ciphertext"], "aabb");
}

#[tokio::test]
async fn file_upload_is_not_acked_until_stored() {
    let base = boot().await;
    let client = reqwest::Client::new();
    let reg = client
        .post(format!("{base}/v1/register"))
        .json(&serde_json::json!({"username": "ada", "password": "secret1"}))
        .send()
        .await
        .unwrap();
    let session: serde_json::Value = reg.json().await.unwrap();
    let token = session["token"].as_str().unwrap().to_string();
    let body = b"hello-syncnotes".to_vec();
    let up = client
        .post(format!("{base}/v1/files"))
        .bearer_auth(&token)
        .header("x-file-name", "aGVsbG8udHh0")
        .body(body.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(up.status(), 200, "{}", up.text().await.unwrap_or_default());
    let meta: serde_json::Value = up.json().await.unwrap();
    assert_eq!(meta["size"], body.len());
    assert_eq!(meta["name"], "hello.txt");
    let id = meta["id"].as_str().unwrap();
    let down = client.get(format!("{base}/v1/files/{id}")).bearer_auth(&token).send().await.unwrap();
    assert_eq!(down.status(), 200);
    assert_eq!(down.bytes().await.unwrap().as_ref(), body.as_slice());
}

#[tokio::test]
async fn websocket_snapshot_and_live_put() {
    let base = boot().await;
    let client = reqwest::Client::new();
    let reg = client
        .post(format!("{base}/v1/register"))
        .json(&serde_json::json!({"username": "ws", "password": "secret1"}))
        .send()
        .await
        .unwrap();
    let session: serde_json::Value = reg.json().await.unwrap();
    let token = session["token"].as_str().unwrap();
    let ws_url = base.replacen("http", "ws", 1);
    let (mut sock, _) = tokio_tungstenite::connect_async(format!("{ws_url}/v1/sync?token={token}")).await.unwrap();
    let hello = tokio::time::timeout(Duration::from_secs(3), sock.next()).await.unwrap().unwrap().unwrap();
    let Message::Text(text) = hello else { panic!("expected text") };
    let v: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
    assert_eq!(v["op"], "snapshot");

    client
        .put(format!("{base}/v1/notes/live1"))
        .bearer_auth(token)
        .json(&serde_json::json!({"updated_at": 3, "nonce": "bg==", "ciphertext": "zz"}))
        .send()
        .await
        .unwrap();
    let live = tokio::time::timeout(Duration::from_secs(3), sock.next()).await.unwrap().unwrap().unwrap();
    let Message::Text(text) = live else { panic!("expected text") };
    let v: serde_json::Value = serde_json::from_str(text.as_str()).unwrap();
    assert_eq!(v["op"], "put");
    assert_eq!(v["note"]["id"], "live1");
    let _ = sock.close(None).await;
}
