//! Shared app state + broadcast hub.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc::UnboundedSender;

use crate::protocol::ServerMessage;
use crate::storage::Storage;

pub type ConnId = u64;

#[derive(Clone)]
pub struct Conn {
    pub user_id: String,
    pub device_id: String,
    pub tx: UnboundedSender<ServerMessage>,
    /// Notified when the session is revoked (password reset) so the socket closes immediately.
    pub kill: Arc<tokio::sync::Notify>,
}

#[derive(Clone)]
pub struct AppState {
    pub storage: Storage,
    pub conns: Arc<Mutex<HashMap<ConnId, Conn>>>,
    pub next_id: Arc<Mutex<ConnId>>,
    pub allow_register: bool,
    pub files_dir: std::path::PathBuf,
    /// Recycle-bin retention in days (0 = keep forever).
    pub trash_days: u32,
    /// Failed-attempt limiter for password recovery (per user and per IP).
    pub recovery_limiter: RateLimiter,
}

/// Fixed-window failure counter. Keys are e.g. `user:bill` / `ip:1.2.3.4`.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<HashMap<String, (u32, std::time::Instant)>>>,
    pub per_user: u32,
    pub per_ip: u32,
    pub window: std::time::Duration,
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self {
            inner: Default::default(),
            per_user: 5,
            per_ip: 20,
            window: std::time::Duration::from_secs(15 * 60),
        }
    }
}

impl RateLimiter {
    fn count(&self, key: &str) -> u32 {
        let mut m = self.inner.lock().unwrap();
        match m.get(key) {
            Some((n, t)) if t.elapsed() < self.window => *n,
            Some(_) => {
                m.remove(key);
                0
            }
            None => 0,
        }
    }

    /// True if either the user or the IP has exhausted its attempts in the current window.
    pub fn blocked(&self, user: &str, ip: &str) -> bool {
        self.count(&format!("user:{user}")) >= self.per_user
            || self.count(&format!("ip:{ip}")) >= self.per_ip
    }

    pub fn fail(&self, user: &str, ip: &str) {
        let mut m = self.inner.lock().unwrap();
        for k in [format!("user:{user}"), format!("ip:{ip}")] {
            let e = m.entry(k).or_insert((0, std::time::Instant::now()));
            if e.1.elapsed() >= self.window {
                *e = (0, std::time::Instant::now());
            }
            e.0 += 1;
        }
        // Bound memory under a spray of random usernames.
        if m.len() > 10_000 {
            let w = self.window;
            m.retain(|_, (_, t)| t.elapsed() < w);
        }
    }

    pub fn reset_user(&self, user: &str) {
        self.inner.lock().unwrap().remove(&format!("user:{user}"));
    }
}

impl AppState {
    pub fn new(storage: Storage, allow_register: bool) -> Self {
        Self {
            storage,
            conns: Default::default(),
            next_id: Arc::new(Mutex::new(1)),
            allow_register,
            files_dir: std::env::temp_dir().join("syncnotes-files"),
            trash_days: 30,
            recovery_limiter: RateLimiter::default(),
        }
    }

    pub fn with_recovery_limits(mut self, per_user: u32, per_ip: u32) -> Self {
        self.recovery_limiter.per_user = per_user;
        self.recovery_limiter.per_ip = per_ip;
        self
    }

    /// Drop every live WebSocket of a user (after password reset / recovery).
    pub fn kick_user(&self, user_id: &str) {
        let mut conns = self.conns.lock().unwrap();
        conns.retain(|_, c| {
            if c.user_id == user_id {
                let _ = c.tx.send(ServerMessage::AuthError {
                    message: "密码已重置，请重新登录".into(),
                });
                c.kill.notify_one();
                false
            } else {
                true
            }
        });
    }

    pub fn has_conn(&self, id: ConnId) -> bool {
        self.conns.lock().unwrap().contains_key(&id)
    }

    pub fn with_files_dir(mut self, d: std::path::PathBuf) -> Self {
        self.files_dir = d;
        self
    }

    pub fn with_trash_days(mut self, d: u32) -> Self {
        self.trash_days = d;
        self
    }

    pub fn register_conn(&self, c: Conn) -> ConnId {
        let mut n = self.next_id.lock().unwrap();
        let id = *n;
        *n += 1;
        self.conns.lock().unwrap().insert(id, c);
        id
    }

    pub fn remove_conn(&self, id: ConnId) {
        self.conns.lock().unwrap().remove(&id);
    }

    /// Send to every connection of a user (including the origin, so it gets the server seq).
    pub fn broadcast_user(&self, user_id: &str, msg: &ServerMessage) {
        for c in self.conns.lock().unwrap().values() {
            if c.user_id == user_id {
                let _ = c.tx.send(msg.clone());
            }
        }
    }

    /// Send only to connections of a specific (user, device).
    pub fn broadcast_device(&self, user_id: &str, device_id: &str, msg: &ServerMessage) {
        for c in self.conns.lock().unwrap().values() {
            if c.user_id == user_id && c.device_id == device_id {
                let _ = c.tx.send(msg.clone());
            }
        }
    }

    pub fn online_count(&self) -> usize {
        self.conns.lock().unwrap().len()
    }
}
