//! SyncNotes WebSocket sync server.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

use syncnotes_server::{AppState, Storage};

#[derive(Parser, Debug)]
#[command(name = "syncnotes-server", version, about = "SyncNotes 实时同步服务器")]
struct Args {
    /// Listen address
    #[arg(long, env = "SYNCNOTES_BIND", default_value = "0.0.0.0:7700")]
    bind: String,

    /// SQLite database path
    #[arg(
        long,
        env = "SYNCNOTES_DB",
        default_value = "syncnotes.db",
        global = true
    )]
    db: PathBuf,

    /// Allow /api/register (set false in production after creating accounts)
    #[arg(long, env = "SYNCNOTES_ALLOW_REGISTER", default_value_t = true, action = clap::ArgAction::Set)]
    allow_register: bool,

    /// Directory for uploaded files (file blocks)
    #[arg(
        long,
        env = "SYNCNOTES_FILES",
        default_value = "syncnotes-files",
        global = true
    )]
    files_dir: PathBuf,

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

fn run_admin(args: &Args, cmd: &AdminCmd) -> Result<(), String> {
    use syncnotes_server::admin;
    if !args.db.exists() {
        return Err(format!(
            "数据库不存在: {}（用 --db 或 SYNCNOTES_DB 指定）",
            args.db.display()
        ));
    }
    let st = Storage::open(&args.db).map_err(|e| format!("打开数据库失败: {e}"))?;
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
            let s = admin::export_user(&st, &args.files_dir, username, out)?;
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

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let args = Args::parse();
    if let Some(Cmd::Admin(cmd)) = &args.cmd {
        if let Err(e) = run_admin(&args, cmd) {
            eprintln!("错误: {e}");
            std::process::exit(1);
        }
        return;
    }
    let storage = Storage::open(&args.db).expect("open db");
    std::fs::create_dir_all(&args.files_dir).expect("create files dir");
    let state = AppState::new(storage, args.allow_register)
        .with_files_dir(args.files_dir.clone())
        .with_trash_days(args.trash_retention_days);

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
    tracing::info!("WebSocket: ws://{addr}/ws  DB: {}", args.db.display());

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
