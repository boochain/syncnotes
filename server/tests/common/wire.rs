//! Test client for the sealed wire. Integration tests share this file via #[path].

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use syncnotes_server::seal::{self, HttpPending, WsPair};
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

fn cache() -> &'static Mutex<HashMap<String, [u8; 32]>> {
    static P: LazyLock<Mutex<HashMap<String, [u8; 32]>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));
    &P
}

pub async fn server_pub(addr: &str) -> [u8; 32] {
    if let Some(p) = cache().lock().unwrap().get(addr).copied() {
        return p;
    }
    let v: Value = reqwest::get(format!("http://{addr}/health"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let p = seal::parse_pub_b64(v["seal_pub"].as_str().unwrap()).unwrap();
    cache().lock().unwrap().insert(addr.to_string(), p);
    p
}

pub struct Ws {
    pub inner: WebSocketStream<MaybeTlsStream<TcpStream>>,
    pair: WsPair,
}

impl Ws {
    pub async fn connect(addr: &str) -> Self {
        let pubk = server_pub(addr).await;
        let (mut inner, _) = connect_async(format!("ws://{addr}/ws")).await.unwrap();
        let hello = seal::ClientHello::new();
        inner
            .send(Message::Binary(hello.frame.clone()))
            .await
            .unwrap();
        let frame = loop {
            let m = tokio::time::timeout(Duration::from_secs(5), inner.next())
                .await
                .expect("handshake timeout")
                .unwrap()
                .unwrap();
            if let Message::Binary(b) = m {
                break b;
            }
        };
        let pair = hello.finish(&pubk, &frame).expect("server identity");
        Self { inner, pair }
    }

    pub async fn send_json(&mut self, v: &Value) {
        let frame = self.pair.send.seal(v.to_string().as_bytes());
        self.inner.send(Message::Binary(frame)).await.unwrap();
    }

    pub async fn recv_json(&mut self) -> Option<Value> {
        loop {
            let next = tokio::time::timeout(Duration::from_secs(5), self.inner.next())
                .await
                .expect("timeout waiting for message");
            let Some(m) = next else {
                return None;
            };
            match m.unwrap() {
                Message::Binary(b) => {
                    let plain = self.pair.recv.open(&b).expect("decrypt");
                    return Some(serde_json::from_slice(&plain).unwrap());
                }
                Message::Close(_) => return None,
                _ => continue,
            }
        }
    }
}

pub async fn post_json(addr: &str, path: &str, token: Option<&str>, body: &Value) -> (u16, Value) {
    let pubk = server_pub(addr).await;
    let hdr = match token {
        Some(t) => json!({"authorization": format!("Bearer {t}")}),
        None => json!({}),
    };
    let pending = HttpPending::seal(
        &pubk,
        1,
        path,
        hdr.to_string().as_bytes(),
        body.to_string().as_bytes(),
    );
    let res = reqwest::Client::new()
        .post(format!("http://{addr}/api/seal"))
        .header("content-type", "application/octet-stream")
        .body(pending.envelope.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(res.status().as_u16(), 200, "outer seal status");
    let bytes = res.bytes().await.unwrap();
    let (st, raw) = pending.open_response(&bytes).unwrap();
    let v = serde_json::from_slice(&raw).unwrap_or(Value::String(String::from_utf8_lossy(&raw).into_owned()));
    (st, v)
}

pub async fn blob_put(addr: &str, token: &str, name: &str, data: &[u8]) -> (u16, Value) {
    let pubk = server_pub(addr).await;
    let meta = json!({"op":"put","name":name,"size":data.len() as u64,"token":token});
    let pending = HttpPending::seal(&pubk, 3, "/api/blob", b"{}", meta.to_string().as_bytes());
    let key = pending.chunk_key();
    let mut body = Vec::new();
    body.extend_from_slice(&(pending.envelope.len() as u32).to_be_bytes());
    body.extend_from_slice(&pending.envelope);
    if !data.is_empty() {
        let ct = seal::seal_chunk(&key, 0, data);
        body.extend_from_slice(&(ct.len() as u32).to_be_bytes());
        body.extend_from_slice(&ct);
    }
    body.extend_from_slice(&0u32.to_be_bytes());
    let res = reqwest::Client::new()
        .post(format!("http://{addr}/api/blob"))
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(res.status().as_u16(), 200, "blob outer");
    let bytes = res.bytes().await.unwrap();
    let (st, raw) = pending.open_response(&bytes).expect("open blob response");
    let v = serde_json::from_slice(&raw).unwrap_or(Value::String(String::from_utf8_lossy(&raw).into_owned()));
    (st, v)
}

pub async fn blob_get(addr: &str, token: &str, id: &str) -> (u16, Vec<u8>) {
    let pubk = server_pub(addr).await;
    let meta = json!({"op":"get","file_id":id,"token":token});
    let pending = HttpPending::seal(&pubk, 3, "/api/blob", b"{}", meta.to_string().as_bytes());
    let mut body = Vec::new();
    body.extend_from_slice(&(pending.envelope.len() as u32).to_be_bytes());
    body.extend_from_slice(&pending.envelope);
    body.extend_from_slice(&0u32.to_be_bytes());
    let res = reqwest::Client::new()
        .post(format!("http://{addr}/api/blob"))
        .body(body)
        .send()
        .await
        .unwrap();
    let bytes = res.bytes().await.unwrap();
    if bytes.len() >= 4 && &bytes[..4] == b"SNC1" {
        let (st, raw) = pending.open_response(&bytes).unwrap_or((500, b"open".to_vec()));
        return (st, raw);
    }
    if bytes.len() < 4 {
        return (500, bytes.to_vec());
    }
    let n = u32::from_be_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let (st, raw) = pending.open_response(&bytes[4..4 + n]).unwrap();
    if st != 200 {
        return (st, raw);
    }
    let key = pending.chunk_key();
    let mut rest = &bytes[4 + n..];
    let mut out = Vec::new();
    let mut idx = 0u64;
    while rest.len() >= 4 {
        let cn = u32::from_be_bytes(rest[..4].try_into().unwrap()) as usize;
        rest = &rest[4..];
        if cn == 0 {
            break;
        }
        let ct = &rest[..cn];
        rest = &rest[cn..];
        out.extend(seal::open_chunk(&key, idx, ct).unwrap());
        idx += 1;
    }
    let _ = raw;
    (200, out)
}
