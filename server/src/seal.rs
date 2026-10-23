//! Application-layer seal (syncnotes-seal-v1).
//!
//! Plaintext exists only inside a client process or the server process.
//! Every HTTP body and WebSocket frame on the wire is ChaCha20-Poly1305
//! ciphertext, so a passive observer of plain HTTP sees no notes, files,
//! passwords, or tokens.
//!
//! HTTP (small JSON): fresh X25519 ephemeral sealed to the server static key.
//! WebSocket: one handshake, then per-direction sequence numbers.
//! Blobs: the same handshake key stream-encrypts independent chunks so a
//! transfer never has to hold the whole file.

use std::path::Path;

use base64::Engine;
use chacha20poly1305::aead::{Aead, Payload};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use rand::rngs::OsRng;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};

pub const HTTP_MAGIC: &[u8] = b"SNC1";
pub const WS_MAGIC: &[u8] = b"SNW1";
pub const WS_DATA: &[u8] = b"SND1";
pub const MAX_CHUNK: usize = 1024 * 1024;
pub const CHUNK: usize = 256 * 1024;

#[derive(Clone)]
pub struct SealIdentity {
    secret: [u8; 32],
    pub public: [u8; 32],
}

impl SealIdentity {
    pub fn generate() -> Self {
        Self::from_secret(StaticSecret::random_from_rng(OsRng).to_bytes())
    }

    pub fn from_secret(secret: [u8; 32]) -> Self {
        let sk = StaticSecret::from(secret);
        let public = PublicKey::from(&sk).to_bytes();
        Self { secret, public }
    }

    pub fn load_or_create(path: &Path) -> std::io::Result<Self> {
        if let Ok(bytes) = std::fs::read(path) {
            if bytes.len() == 32 {
                let mut secret = [0u8; 32];
                secret.copy_from_slice(&bytes);
                return Ok(Self::from_secret(secret));
            }
        }
        let id = Self::generate();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            let mut opts = std::fs::OpenOptions::new();
            opts.write(true).create(true).truncate(true).mode(0o600);
            use std::io::Write;
            opts.open(path)?.write_all(&id.secret)?;
        }
        #[cfg(not(unix))]
        {
            std::fs::write(path, id.secret)?;
        }
        Ok(id)
    }

    pub fn fingerprint(&self) -> String {
        self.public.iter().map(|b| format!("{b:02x}")).collect()
    }

    pub fn public_b64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.public)
    }

    fn static_secret(&self) -> StaticSecret {
        StaticSecret::from(self.secret)
    }
}

fn hkdf(ikm: &[u8], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(Some(b"syncnotes-seal-v1"), ikm);
    let mut okm = [0u8; 32];
    hk.expand(info, &mut okm).expect("hkdf");
    okm
}

fn aead_seal(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], plain: &[u8]) -> Vec<u8> {
    let cipher = ChaCha20Poly1305::new(key.into());
    cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload { msg: plain, aad },
        )
        .expect("encrypt")
}

fn aead_open(key: &[u8; 32], nonce: &[u8; 12], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>, ()> {
    let cipher = ChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad })
        .map_err(|_| ())
}

fn shared_with(secret: &StaticSecret, remote: &[u8; 32]) -> [u8; 32] {
    let pk = PublicKey::from(*remote);
    let s = secret.diffie_hellman(&pk);
    *s.as_bytes()
}

fn random_nonce() -> [u8; 12] {
    use rand::RngCore;
    let mut n = [0u8; 12];
    OsRng.fill_bytes(&mut n);
    n
}

/// Client (or test) state for one sealed HTTP request. Also derives blob chunk keys.
pub struct HttpPending {
    eph_secret: [u8; 32],
    server_pub: [u8; 32],
    pub envelope: Vec<u8>,
}

impl HttpPending {
    /// `method`: 1 POST, 2 GET, 3 PUT.
    pub fn seal(
        server_pub: &[u8; 32],
        method: u8,
        path: &str,
        headers_json: &[u8],
        body: &[u8],
    ) -> Self {
        let eph = StaticSecret::random_from_rng(OsRng);
        let eph_pub = PublicKey::from(&eph).to_bytes();
        let eph_secret = eph.to_bytes();
        let shared = shared_with(&eph, server_pub);
        let key = hkdf(&shared, b"http-req");
        let mut plain = Vec::with_capacity(3 + path.len() + headers_json.len() + body.len());
        plain.push(method);
        let pb = path.as_bytes();
        plain.extend_from_slice(&(pb.len() as u16).to_be_bytes());
        plain.extend_from_slice(pb);
        plain.extend_from_slice(&(headers_json.len() as u16).to_be_bytes());
        plain.extend_from_slice(headers_json);
        plain.extend_from_slice(body);
        let nonce = random_nonce();
        let ct = aead_seal(&key, &nonce, b"syncnotes-http-v1-req", &plain);
        let mut envelope = Vec::with_capacity(4 + 32 + 12 + ct.len());
        envelope.extend_from_slice(HTTP_MAGIC);
        envelope.extend_from_slice(&eph_pub);
        envelope.extend_from_slice(&nonce);
        envelope.extend_from_slice(&ct);
        Self {
            eph_secret,
            server_pub: *server_pub,
            envelope,
        }
    }

    fn shared(&self) -> [u8; 32] {
        shared_with(&StaticSecret::from(self.eph_secret), &self.server_pub)
    }

    pub fn open_response(&self, envelope: &[u8]) -> Result<(u16, Vec<u8>), ()> {
        let ct = open_envelope(envelope, &self.shared(), b"http-res", b"syncnotes-http-v1-res")?;
        if ct.len() < 2 {
            return Err(());
        }
        let status = u16::from_be_bytes([ct[0], ct[1]]);
        Ok((status, ct[2..].to_vec()))
    }

    pub fn chunk_key(&self) -> [u8; 32] {
        hkdf(&self.shared(), b"blob")
    }
}

pub struct OpenedHttp {
    pub method: u8,
    pub path: String,
    pub headers_json: Vec<u8>,
    pub body: Vec<u8>,
    shared: [u8; 32],
}

impl OpenedHttp {
    pub fn open(identity: &SealIdentity, envelope: &[u8]) -> Result<Self, ()> {
        if envelope.len() < 4 + 32 + 12 + 16 || &envelope[..4] != HTTP_MAGIC {
            return Err(());
        }
        let mut eph_pub = [0u8; 32];
        eph_pub.copy_from_slice(&envelope[4..36]);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&envelope[36..48]);
        let shared = shared_with(&identity.static_secret(), &eph_pub);
        let key = hkdf(&shared, b"http-req");
        let plain = aead_open(&key, &nonce, b"syncnotes-http-v1-req", &envelope[48..])?;
        if plain.len() < 1 + 2 + 2 {
            return Err(());
        }
        let method = plain[0];
        let path_len = u16::from_be_bytes([plain[1], plain[2]]) as usize;
        if plain.len() < 3 + path_len + 2 {
            return Err(());
        }
        let path = std::str::from_utf8(&plain[3..3 + path_len])
            .map_err(|_| ())?
            .to_string();
        let h0 = 3 + path_len;
        let hdr_len = u16::from_be_bytes([plain[h0], plain[h0 + 1]]) as usize;
        if plain.len() < h0 + 2 + hdr_len {
            return Err(());
        }
        let headers_json = plain[h0 + 2..h0 + 2 + hdr_len].to_vec();
        let body = plain[h0 + 2 + hdr_len..].to_vec();
        Ok(Self {
            method,
            path,
            headers_json,
            body,
            shared,
        })
    }

    pub fn seal_response(&self, status: u16, body: &[u8]) -> Vec<u8> {
        let mut plain = Vec::with_capacity(2 + body.len());
        plain.extend_from_slice(&status.to_be_bytes());
        plain.extend_from_slice(body);
        seal_envelope(&self.shared, b"http-res", b"syncnotes-http-v1-res", &plain)
    }

    pub fn chunk_key(&self) -> [u8; 32] {
        hkdf(&self.shared, b"blob")
    }
}

fn open_envelope(envelope: &[u8], shared: &[u8; 32], info: &[u8], aad: &[u8]) -> Result<Vec<u8>, ()> {
    if envelope.len() < 4 + 32 + 12 + 16 || &envelope[..4] != HTTP_MAGIC {
        return Err(());
    }
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&envelope[36..48]);
    let key = hkdf(shared, info);
    aead_open(&key, &nonce, aad, &envelope[48..])
}

fn seal_envelope(shared: &[u8; 32], info: &[u8], aad: &[u8], plain: &[u8]) -> Vec<u8> {
    // Response envelopes reuse a fresh ephemeral so the nonce never repeats
    // under this derived key. The peer opens with the shared secret from the
    // request, so the ephemeral here is only a nonce carrier: put zeros in the
    // public slot and a random nonce. The key does not depend on this pub.
    let nonce = random_nonce();
    let key = hkdf(shared, info);
    let ct = aead_seal(&key, &nonce, aad, plain);
    let mut out = Vec::with_capacity(48 + ct.len());
    out.extend_from_slice(HTTP_MAGIC);
    out.extend_from_slice(&[0u8; 32]);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    out
}

pub fn chunk_nonce(idx: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&idx.to_be_bytes());
    n
}

pub fn seal_chunk(key: &[u8; 32], idx: u64, plain: &[u8]) -> Vec<u8> {
    let n = chunk_nonce(idx);
    aead_seal(key, &n, b"syncnotes-blob-v1", plain)
}

pub fn open_chunk(key: &[u8; 32], idx: u64, ct: &[u8]) -> Result<Vec<u8>, ()> {
    let n = chunk_nonce(idx);
    aead_open(key, &n, b"syncnotes-blob-v1", ct)
}

pub struct WsDir {
    key: [u8; 32],
    dir: u8,
    seq: u64,
}

impl WsDir {
    fn new(key: [u8; 32], dir: u8) -> Self {
        Self { key, dir, seq: 0 }
    }

    pub fn seal(&mut self, plain: &[u8]) -> Vec<u8> {
        self.seq += 1;
        let nonce = dir_nonce(self.dir, self.seq);
        let mut aad = b"syncnotes-ws-v1".to_vec();
        aad.push(self.dir);
        let ct = aead_seal(&self.key, &nonce, &aad, plain);
        let mut out = Vec::with_capacity(4 + 8 + ct.len());
        out.extend_from_slice(WS_DATA);
        out.extend_from_slice(&self.seq.to_be_bytes());
        out.extend_from_slice(&ct);
        out
    }

    pub fn open(&mut self, frame: &[u8]) -> Result<Vec<u8>, ()> {
        if frame.len() < 4 + 8 + 16 || &frame[..4] != WS_DATA {
            return Err(());
        }
        let seq = u64::from_be_bytes(frame[4..12].try_into().unwrap());
        if seq != self.seq + 1 {
            return Err(());
        }
        self.seq = seq;
        let nonce = dir_nonce(self.dir, seq);
        let mut aad = b"syncnotes-ws-v1".to_vec();
        aad.push(self.dir);
        aead_open(&self.key, &nonce, &aad, &frame[12..])
    }
}

fn dir_nonce(dir: u8, seq: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[0] = dir;
    n[1..9].copy_from_slice(&seq.to_be_bytes());
    n
}

pub struct WsPair {
    /// Frames this side sends (client dir 1, server dir 2).
    pub send: WsDir,
    /// Frames this side receives.
    pub recv: WsDir,
}

pub struct ClientHello {
    eph_secret: [u8; 32],
    pub frame: Vec<u8>,
}

impl ClientHello {
    pub fn new() -> Self {
        let eph = StaticSecret::random_from_rng(OsRng);
        let pub_b = PublicKey::from(&eph).to_bytes();
        let mut frame = Vec::with_capacity(36);
        frame.extend_from_slice(WS_MAGIC);
        frame.extend_from_slice(&pub_b);
        Self {
            eph_secret: eph.to_bytes(),
            frame,
        }
    }

    pub fn finish(self, server_pub: &[u8; 32], server_frame: &[u8]) -> Result<WsPair, ()> {
        if server_frame.len() != 4 + 32 + 16 || &server_frame[..4] != WS_MAGIC {
            return Err(());
        }
        let mut server_eph = [0u8; 32];
        server_eph.copy_from_slice(&server_frame[4..36]);
        let tag = &server_frame[36..];
        let eph = StaticSecret::from(self.eph_secret);
        let ss_e = shared_with(&eph, &server_eph);
        let ss_s = shared_with(&eph, server_pub);
        let mut ikm = [0u8; 64];
        ikm[..32].copy_from_slice(&ss_e);
        ikm[32..].copy_from_slice(&ss_s);
        let key = hkdf(&ikm, b"ws");
        let client_eph = PublicKey::from(&eph).to_bytes();
        let mut aad = Vec::with_capacity(64);
        aad.extend_from_slice(&client_eph);
        aad.extend_from_slice(&server_eph);
        // Handshake proof is an encryption of empty plaintext; ciphertext is the tag.
        let expect = aead_seal(&key, &[0u8; 12], &aad, b"");
        if expect.as_slice() != tag {
            return Err(());
        }
        Ok(WsPair {
            send: WsDir::new(key, 1),
            recv: WsDir::new(key, 2),
        })
    }
}

pub fn accept_client_hello(identity: &SealIdentity, frame: &[u8]) -> Result<(Vec<u8>, WsPair), ()> {
    if frame.len() != 36 || &frame[..4] != WS_MAGIC {
        return Err(());
    }
    let mut client_eph = [0u8; 32];
    client_eph.copy_from_slice(&frame[4..36]);
    let eph = StaticSecret::random_from_rng(OsRng);
    let server_eph = PublicKey::from(&eph).to_bytes();
    let ss_e = shared_with(&eph, &client_eph);
    let ss_s = shared_with(&identity.static_secret(), &client_eph);
    let mut ikm = [0u8; 64];
    ikm[..32].copy_from_slice(&ss_e);
    ikm[32..].copy_from_slice(&ss_s);
    let key = hkdf(&ikm, b"ws");
    let mut aad = Vec::with_capacity(64);
    aad.extend_from_slice(&client_eph);
    aad.extend_from_slice(&server_eph);
    let tag = aead_seal(&key, &[0u8; 12], &aad, b"");
    let mut hello = Vec::with_capacity(4 + 32 + 16);
    hello.extend_from_slice(WS_MAGIC);
    hello.extend_from_slice(&server_eph);
    hello.extend_from_slice(&tag);
    let pair = WsPair {
        send: WsDir::new(key, 2),
        recv: WsDir::new(key, 1),
    };
    Ok((hello, pair))
}

pub fn parse_pub_b64(s: &str) -> Result<[u8; 32], ()> {
    let v = base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .map_err(|_| ())?;
    if v.len() != 32 {
        return Err(());
    }
    let mut o = [0u8; 32];
    o.copy_from_slice(&v);
    Ok(o)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_roundtrip_hides_plaintext() {
        let id = SealIdentity::generate();
        let password = b"super-secret-password";
        let pending = HttpPending::seal(&id.public, 1, "/api/login", b"{}", password);
        assert!(!pending.envelope.windows(password.len()).any(|w| w == password));
        let opened = OpenedHttp::open(&id, &pending.envelope).unwrap();
        assert_eq!(opened.path, "/api/login");
        assert_eq!(opened.body, password);
        let env = opened.seal_response(401, b"nope");
        assert!(!env.windows(4).any(|w| w == b"nope"));
        let (st, body) = pending.open_response(&env).unwrap();
        assert_eq!(st, 401);
        assert_eq!(body, b"nope");
    }

    #[test]
    fn chunk_and_ws_roundtrip() {
        let id = SealIdentity::generate();
        let pending = HttpPending::seal(&id.public, 3, "/api/blob", b"{}", b"meta");
        let opened = OpenedHttp::open(&id, &pending.envelope).unwrap();
        let ck = opened.chunk_key();
        assert_eq!(ck, pending.chunk_key());
        let ct = seal_chunk(&ck, 0, b"hello file");
        assert!(!ct.windows(5).any(|w| w == b"hello"));
        assert_eq!(open_chunk(&pending.chunk_key(), 0, &ct).unwrap(), b"hello file");

        let hello = ClientHello::new();
        let (frame, mut server) = accept_client_hello(&id, &hello.frame).unwrap();
        let mut client = hello.finish(&id.public, &frame).unwrap();
        let c = client.send.seal(b"{\"type\":\"ping\"}");
        assert!(!c.windows(4).any(|w| w == b"ping"));
        assert_eq!(server.recv.open(&c).unwrap(), b"{\"type\":\"ping\"}");
        let s = server.send.seal(b"{\"type\":\"pong\"}");
        assert_eq!(client.recv.open(&s).unwrap(), b"{\"type\":\"pong\"}");
    }

    #[test]
    fn vector_for_clients() {
        fn hx(b: &[u8]) -> String {
            b.iter().map(|x| format!("{x:02x}")).collect()
        }
        let server = SealIdentity::from_secret([2u8; 32]);
        let eph = StaticSecret::from([3u8; 32]);
        let shared = shared_with(&eph, &server.public);
        let key = hkdf(&shared, b"http-req");
        let ct = aead_seal(&key, &[9u8; 12], b"syncnotes-http-v1-req", b"hi");
        println!("PUB {}", hx(&server.public));
        println!("EPH {}", hx(&PublicKey::from(&eph).to_bytes()));
        println!("SHARED {}", hx(&shared));
        println!("KEY {}", hx(&key));
        println!("CT {}", hx(&ct));
    }

    #[test]
    fn rejects_wrong_server_key() {
        let id = SealIdentity::generate();
        let other = SealIdentity::generate();
        let hello = ClientHello::new();
        let (frame, _) = accept_client_hello(&id, &hello.frame).unwrap();
        assert!(hello.finish(&other.public, &frame).is_err());
    }
}
