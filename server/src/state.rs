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
}

#[derive(Clone)]
pub struct AppState {
    pub storage: Storage,
    pub conns: Arc<Mutex<HashMap<ConnId, Conn>>>,
    pub next_id: Arc<Mutex<ConnId>>,
    pub allow_register: bool,
    pub files_dir: std::path::PathBuf,
}

impl AppState {
    pub fn new(storage: Storage, allow_register: bool) -> Self {
        Self {
            storage,
            conns: Default::default(),
            next_id: Arc::new(Mutex::new(1)),
            allow_register,
            files_dir: std::env::temp_dir().join("syncnotes-files"),
        }
    }

    pub fn with_files_dir(mut self, d: std::path::PathBuf) -> Self {
        self.files_dir = d;
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
