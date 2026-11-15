//! SyncNotes WebSocket sync server.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

use syncnotes_server::{seal::SealIdentity, AppState, Storage};

#[derive(Parser, Debug)]
#[command(name = "syncnotes-server", version, about = "SyncNotes 实时同步服务器")]
struct Args {
    /// Listen address
    #[arg(long, env = "SYNCNOTES_BIND", default_value = "0.0.0.0:7700")]
    bind: String,

    /// SQLite 数据库路径。不填则放在独立数据目录，不放在这个版本的程序目录里。
    #[arg(long, env = "SYNCNOTES_DB", global = true)]
    db: Option<PathBuf>,

    /// Allow /api/register (set false in production after creating accounts)
    #[arg(long, env = "SYNCNOTES_ALLOW_REGISTER", default_value_t = true, action = clap::ArgAction::Set)]
    allow_register: bool,

    /// 上传文件目录。不填则放在数据目录里的 syncnotes-files。
    #[arg(long, env = "SYNCNOTES_FILES", global = true)]
    files_dir: Option<PathBuf>,

    /// Recycle-bin retention in days; items older than this are purged permanently (0 = never)
    #[arg(long, env = "SYNCNOTES_TRASH_DAYS", default_value_t = 30)]
    trash_retention_days: u32,

    /// Advertise via mDNS as _syncnotes._tcp.local.
    #[arg(long, env = "SYNCNOTES_MDNS", default_value_t = true, action = clap::ArgAction::Set)]
    mdns: bool,

    /// Instance name for mDNS
    #[arg(long, env = "SYNCNOTES_MDNS_NAME", default_value = "SyncNotes")]
    mdns_name: String,

    #[command(subcommand)]
    cmd: Option<Cmd>,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// 管理员救援工具（忘记密码 / 导出数据 / 备份），可在服务器运行时使用
    #[command(subcommand)]
    Admin(AdminCmd),
}

#[derive(Subcommand, Debug)]
enum AdminCmd {
    /// 列出所有用户
    ListUsers,
    /// 重置用户密码（使所有已登录设备失效；数据不受影响）
    ResetPassword {
        username: String,
        /// 新密码（会出现在 shell 历史/进程列表中，建议用 --password-stdin 或自动生成）
        #[arg(long, conflicts_with = "password_stdin")]
        password: Option<String>,
        /// 从标准输入读取新密码（一行）
        #[arg(long)]
        password_stdin: bool,
        /// 不要求用户下次登录后修改密码
        #[arg(long)]
        no_force_change: bool,
    },
    /// 导出用户全部数据（含回收站）为 zip：JSON + Markdown + 附件
    Export { username: String, out: PathBuf },
    /// 在线备份数据库（VACUUM INTO，服务器运行时也安全）
    Backup { out: PathBuf },
}

fn run_admin(db: &std::path::Path, files: &std::path::Path, cmd: &AdminCmd) -> Result<(), String> {
    use syncnotes_server::admin;
    if !db.exists() {
        return Err(format!(
            "数据库不存在: {}（用 --db 或 SYNCNOTES_DB 指定）",
            db.display()
        ));
    }
    let st = Storage::open(db).map_err(|e| format!("打开数据库失败: {e}"))?;
    match cmd {
        AdminCmd::ListUsers => {
            print!("{}", admin::format_users(&admin::list_users(&st)?));
        }
        AdminCmd::ResetPassword {
            username,
            password,
            password_stdin,
            no_force_change,
        } => {
            let pw = if *password_stdin {
                let mut l = String::new();
                std::io::stdin()
                    .read_line(&mut l)
                    .map_err(|e| e.to_string())?;
                Some(l.trim_end_matches(['\r', '\n']).to_string())
            } else {
                password.clone()
            };
            let r = admin::reset_password(&st, username, pw, !no_force_change)?;
            println!(
                "已重置用户 {username} 的密码，{} 个登录会话已失效。",
                r.revoked_tokens
            );
            if r.generated {
                println!("临时密码: {}", r.password);
            }
            if !no_force_change {
                println!("用户用此密码登录后会被要求立即设置新密码。");
            }
            println!("笔记、文件、回收站均未改动。建议用户登录后在 设置 → 账号 重新生成恢复码。");
        }
        AdminCmd::Export { username, out } => {
            let s = admin::export_user(&st, files, username, out)?;
            println!(
                "已导出 {}：{} 个块（回收站 {} 个），{} 个附件{} → {}",
                username,
                s.blocks,
                s.trashed,
                s.files,
                if s.missing_files > 0 {
                    format!("，{} 个附件文件缺失", s.missing_files)
                } else {
                    String::new()
                },
                s.out.display()
            );
        }
        AdminCmd::Backup { out } => {
            admin::backup(&st, out)?;
            println!("数据库已备份到 {}", out.display());
        }
    }
    Ok(())
}

fn prepare_layout(args: &Args) -> std::io::Result<syncnotes_server::paths::DataLayout> {
    use syncnotes_server::paths::{self, LayoutInput};
    let data_dir = if args.db.is_none() {
        paths::pick_data_dir(&paths::DataDirEnv::from_process())
    } else {
        PathBuf::new()
    };
    let mut legacy = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        legacy.push(cwd);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            legacy.push(dir.to_path_buf());
        }
    }
    paths::resolve_layout(LayoutInput {
        explicit_db: args.db.as_deref(),
        explicit_files: args.files_dir.as_deref(),
        data_dir: &data_dir,
        legacy_dirs: &legacy,
    })
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let args = Args::parse();
    let layout = match prepare_layout(&args) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("数据目录不可用: {e}");
            std::process::exit(1);
        }
    };
    if let Some(Cmd::Admin(cmd)) = &args.cmd {
        if let Err(e) = run_admin(&layout.db, &layout.files, cmd) {
            eprintln!("错误: {e}");
            std::process::exit(1);
        }
        return;
    }
    tracing::info!(
        "数据目录 {}（和程序分开存放，换版本不会丢）",
        layout.db.parent().unwrap_or(std::path::Path::new(".")).display()
    );
    if let Some(from) = &layout.migrated_from {
        tracing::info!(
            "已把 {} 里的旧数据复制到数据目录，原文件还留着，确认没问题后可以自行删除",
            from.display()
        );
    } else if layout.fresh {
        tracing::info!(
            "数据目录是空的。如果旧数据库还在之前的版本目录里，把 syncnotes.db、syncnotes.db.seal 和 syncnotes-files 复制到这里，或在那个旧目录里启动一次本程序"
        );
    }
    let storage = Storage::open(&layout.db).expect("open db");
    std::fs::create_dir_all(&layout.files).expect("create files dir");
    let mut seal_path = layout.db.as_os_str().to_owned();
    seal_path.push(".seal");
    let seal = SealIdentity::load_or_create(std::path::Path::new(&seal_path)).expect("seal key");
    tracing::info!(
        "传输加密 syncnotes-seal-v1 指纹 {}",
        &seal.fingerprint()[..16]
    );
    let state = AppState::new(storage, args.allow_register)
        .with_files_dir(layout.files.clone())
        .with_trash_days(args.trash_retention_days)
        .with_seal(seal);

    if args.trash_retention_days > 0 {
        let st = state.clone();
        let days = args.trash_retention_days;
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let n = syncnotes_server::trash::purge_expired(
                    &st,
                    days,
                    chrono::Utc::now().timestamp_millis(),
                );
                if n > 0 {
                    tracing::info!("回收站：已彻底删除 {n} 个超过 {days} 天的项目");
                }
            }
        });
    }

    let app = syncnotes_server::build_router(state);

    let addr: SocketAddr = args.bind.parse().expect("invalid bind address");
    tracing::info!("SyncNotes server listening on http://{addr}");
    tracing::info!("WebSocket: ws://{addr}/ws  DB: {}", layout.db.display());

    if args.mdns {
        spawn_mdns(&args.mdns_name, addr.port());
    }

    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .expect("serve");
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
