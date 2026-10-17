//! SyncNotes WebSocket sync server.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use clap::Parser;
use tracing_subscriber::EnvFilter;

use syncnotes_server::{AppState, Storage};

#[derive(Parser, Debug)]
#[command(name = "syncnotes-server", version, about = "SyncNotes 实时同步服务器")]
struct Args {
    /// Listen address
    #[arg(long, env = "SYNCNOTES_BIND", default_value = "0.0.0.0:7700")]
    bind: String,

    /// SQLite database path
    #[arg(long, env = "SYNCNOTES_DB", default_value = "syncnotes.db")]
    db: PathBuf,

    /// Allow /api/register (set false in production after creating accounts)
    #[arg(long, env = "SYNCNOTES_ALLOW_REGISTER", default_value_t = true, action = clap::ArgAction::Set)]
    allow_register: bool,

    /// Directory for uploaded files (file blocks)
    #[arg(long, env = "SYNCNOTES_FILES", default_value = "syncnotes-files")]
    files_dir: PathBuf,

    /// Advertise via mDNS as _syncnotes._tcp.local.
    #[arg(long, env = "SYNCNOTES_MDNS", default_value_t = true, action = clap::ArgAction::Set)]
    mdns: bool,

    /// Instance name for mDNS
    #[arg(long, env = "SYNCNOTES_MDNS_NAME", default_value = "SyncNotes")]
    mdns_name: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let args = Args::parse();
    let storage = Storage::open(&args.db).expect("open db");
    std::fs::create_dir_all(&args.files_dir).expect("create files dir");
    let state = AppState::new(storage, args.allow_register).with_files_dir(args.files_dir.clone());

    let app = syncnotes_server::build_router(state);

    let addr: SocketAddr = args.bind.parse().expect("invalid bind address");
    tracing::info!("SyncNotes server listening on http://{addr}");
    tracing::info!("WebSocket: ws://{addr}/ws  DB: {}", args.db.display());

    if args.mdns {
        spawn_mdns(&args.mdns_name, addr.port());
    }

    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(listener, app).await.expect("serve");
}

fn spawn_mdns(name: &str, port: u16) {
    let name = name.to_string();
    tokio::task::spawn_blocking(move || {
        match mdns_sd::ServiceDaemon::new() {
            Ok(daemon) => {
                let service = mdns_sd::ServiceInfo::new(
                    "_syncnotes._tcp.local.",
                    &name,
                    &format!("{name}.local."),
                    "",
                    port,
                    &[("path", "/ws"), ("proto", "syncnotes/0.1")][..],
                );
                match service {
                    Ok(info) => {
                        let info = info.enable_addr_auto();
                        // Prefer LAN IP if available; mdns-sd can resolve host.
                        if let Err(e) = daemon.register(info) {
                            tracing::warn!("mDNS register failed: {e}");
                            return;
                        }
                        tracing::info!("mDNS advertising _syncnotes._tcp on port {port}");
                        // Keep daemon alive
                        loop {
                            std::thread::sleep(Duration::from_secs(3600));
                        }
                    }
                    Err(e) => tracing::warn!("mDNS ServiceInfo: {e}"),
                }
            }
            Err(e) => tracing::warn!("mDNS daemon unavailable (LAN discovery disabled): {e}"),
        }
    });
}
