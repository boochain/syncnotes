use std::path::PathBuf;

use clap::Parser;
use tracing_subscriber::EnvFilter;

use syncnotes_server::{serve, AppState};

#[derive(Parser, Debug)]
#[command(name = "syncnotes-server", version, about = "SyncNotes 同步服务器")]
struct Args {
    #[arg(long, env = "SYNCNOTES_BIND", default_value = "0.0.0.0:7700")]
    bind: String,

    #[arg(long, env = "SYNCNOTES_DB")]
    db: Option<PathBuf>,

    #[arg(long, env = "SYNCNOTES_FILES")]
    files_dir: Option<PathBuf>,

    #[arg(long, env = "SYNCNOTES_ALLOW_REGISTER", default_value_t = true, action = clap::ArgAction::Set)]
    allow_register: bool,
}

fn data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("SYNCNOTES_DATA_DIR") {
        return PathBuf::from(dir);
    }
    if cfg!(windows) {
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            return PathBuf::from(local).join("SyncNotes");
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join(".local").join("share").join("syncnotes");
    }
    PathBuf::from("syncnotes-data")
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter(EnvFilter::from_default_env()).init();
    let args = Args::parse();
    let root = data_dir();
    let db = args.db.unwrap_or_else(|| root.join("syncnotes.db"));
    let files = args.files_dir.unwrap_or_else(|| root.join("files"));
    let state = match AppState::open(&db, &files, args.allow_register) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("无法打开数据目录：{e}");
            std::process::exit(1);
        }
    };
    tracing::info!("database {}", db.display());
    if let Err(e) = serve(state, &args.bind).await {
        eprintln!("服务器退出：{e}");
        std::process::exit(1);
    }
}
