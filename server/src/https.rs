//! 给已经在运行的 Nginx 加一个 HTTPS 站点。
//!
//! 不启动第二套 Web 服务器，所以不会和现有网站抢 80/443。
//! 只新增一个配置文件；`nginx -t` 失败就还原，不 reload。

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use instant_acme::{
    Account, AccountCredentials, AuthorizationStatus, ChallengeType, Identifier, LetsEncrypt,
    NewAccount, NewOrder, OrderStatus, RetryPolicy,
};
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct StoredAccount {
    directory_url: String,
    credentials: AccountCredentials,
}

const MANAGED_MARK: &str = "# syncnotes-managed:";
const RENEW_WITHIN_SECS: i64 = 30 * 24 * 60 * 60;

/// `syncnotes-server https` 的参数。命令行解析在二进制里，这里只收已经拆好的值。
pub struct HttpsRequest {
    pub domain: Option<String>,
    pub email: Option<String>,
    pub upstream: String,
    pub state_dir: Option<PathBuf>,
    pub nginx_bin: Option<PathBuf>,
    pub cert: Option<PathBuf>,
    pub key: Option<PathBuf>,
    pub staging: bool,
    pub allow_panel: bool,
    pub no_schedule: bool,
    pub renew: bool,
    pub force: bool,
    pub no_preflight: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct HttpsState {
    domain: String,
    upstream: String,
    webroot: PathBuf,
    conf_file: PathBuf,
    cert_file: PathBuf,
    key_file: PathBuf,
    account_file: PathBuf,
    directory_url: String,
    nginx_bin: PathBuf,
    external_cert: bool,
    email: Option<String>,
}

struct NginxInfo {
    bin: PathBuf,
    version: (u32, u32, u32),
    prefix: PathBuf,
    conf: PathBuf,
}

struct HttpBlock {
    open_brace: usize,
    includes: Vec<String>,
}

struct ConfTxn {
    path: PathBuf,
    previous: Option<Vec<u8>>,
}

impl ConfTxn {
    fn begin(path: &Path) -> Result<Self, String> {
        let previous = if path.exists() {
            Some(fs::read(path).map_err(|e| format!("读取 {} 失败: {e}", path.display()))?)
        } else {
            None
        };
        Ok(Self {
            path: path.to_path_buf(),
            previous,
        })
    }

    fn write(&self, body: &str) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("创建目录失败: {e}"))?;
        }
        let tmp = self.path.with_extension("conf.tmp");
        fs::write(&tmp, body).map_err(|e| format!("写入 {} 失败: {e}", tmp.display()))?;
        fs::rename(&tmp, &self.path).map_err(|e| format!("写入 {} 失败: {e}", self.path.display()))?;
        Ok(())
    }

    fn rollback(&self) -> Result<(), String> {
        match &self.previous {
            Some(bytes) => fs::write(&self.path, bytes)
                .map_err(|e| format!("还原 {} 失败: {e}", self.path.display())),
            None => {
                if self.path.exists() {
                    fs::remove_file(&self.path)
                        .map_err(|e| format!("删除 {} 失败: {e}", self.path.display()))?;
                }
                Ok(())
            }
        }
    }
}

pub async fn execute(req: HttpsRequest) -> Result<(), String> {
    if req.renew {
        return renew(&req).await;
    }
    setup(&req).await
}

async fn setup(req: &HttpsRequest) -> Result<(), String> {
    let domain = normalize_domain(req.domain.as_deref().unwrap_or(""))?;
    let upstream = normalize_upstream(&req.upstream)?;
    if let Some(email) = req.email.as_deref() {
        check_email(email)?;
    }
    let (external_cert, external_key) = match (&req.cert, &req.key) {
        (Some(c), Some(k)) => (Some(canonicalize_existing(c)?), Some(canonicalize_existing(k)?)),
        (None, None) => (None, None),
        _ => return Err("--cert 和 --key 必须同时提供".into()),
    };

    let nginx = probe_nginx(req.nginx_bin.as_deref())?;
    let main = fs::read_to_string(&nginx.conf)
        .map_err(|e| format!("读取 {} 失败: {e}", nginx.conf.display()))?;
    let block = parse_http(&main)?;
    let includes = block
        .includes
        .iter()
        .map(|p| resolve_include(&nginx.prefix, p))
        .collect::<Vec<_>>();

    if let Some(kind) = panel_of(&nginx, &includes) {
        if !req.allow_panel {
            return Err(panel_message(kind, &domain, &upstream));
        }
        println!("检测到{kind}。已按 --allow-panel 继续，面板之后如果重写网站配置，这个站点可能会消失。");
    }

    let state_dir = req
        .state_dir
        .clone()
        .unwrap_or_else(default_state_dir);
    fs::create_dir_all(&state_dir).map_err(|e| {
        format!(
            "无法创建 {}（{e}）。请用管理员运行，或加上 --state-dir 指到一个可写目录。",
            state_dir.display()
        )
    })?;
    let webroot = state_dir.join("webroot");
    fs::create_dir_all(&webroot).map_err(|e| format!("创建验证目录失败: {e}"))?;

    let directory_url = if req.staging {
        LetsEncrypt::Staging.url().to_string()
    } else {
        LetsEncrypt::Production.url().to_string()
    };

    let mut state = HttpsState {
        domain: domain.clone(),
        upstream: upstream.clone(),
        webroot: webroot.clone(),
        conf_file: PathBuf::new(),
        cert_file: external_cert
            .clone()
            .unwrap_or_else(|| state_dir.join("certs").join("fullchain.pem")),
        key_file: external_key
            .clone()
            .unwrap_or_else(|| state_dir.join("certs").join("privkey.pem")),
        account_file: state_dir.join("account.json"),
        directory_url,
        nginx_bin: nginx.bin.clone(),
        external_cert: external_cert.is_some(),
        email: req.email.clone(),
    };

    let (drop_dir, inserted_main) = ensure_drop_dir(&nginx, &main, &block, &includes)?;
    let conf_path = drop_dir.join(format!("syncnotes-{domain}.conf"));
    state.conf_file = conf_path.clone();
    scan_conflicts(&nginx.conf, &includes, &conf_path, &domain)?;

    let saved = load_state(&state_dir).ok();
    let reuse_cert = !state.external_cert
        && saved.as_ref().is_some_and(|old| {
            old.domain == domain
                && old.directory_url == state.directory_url
                && !old.external_cert
                && cert_still_good(&old.cert_file, 7 * 24 * 60 * 60)
        });
    if reuse_cert {
        if let Some(old) = &saved {
            state.cert_file = old.cert_file.clone();
            state.key_file = old.key_file.clone();
            state.account_file = old.account_file.clone();
        }
        println!("已有还没到期的证书，跳过重新申请。");
    }

    let base = RenderOpts {
        domain: &domain,
        upstream: &upstream,
        webroot: &nginx_path(&webroot),
        cert: None,
        key: None,
        ipv6: true,
        http2_on: http2_directive(nginx.version),
    };

    let txn = ConfTxn::begin(&conf_path)?;
    let publish = |body_of: &dyn Fn(bool, bool) -> String| -> Result<(), String> {
        let mut last = String::new();
        for (ipv6, http2_on) in feature_order(base.http2_on) {
            txn.write(&body_of(ipv6, http2_on))?;
            match nginx_test(&nginx.bin) {
                Ok(()) => return Ok(()),
                Err(e) => last = e,
            }
        }
        txn.rollback()?;
        let _ = nginx_test(&nginx.bin);
        Err(format!("Nginx 没有接受新配置，已还原，原来的网站没有改。\n{last}"))
    };

    if state.external_cert {
        publish(&|ipv6, http2_on| {
            render(&RenderOpts {
                cert: Some(&nginx_path(&state.cert_file)),
                key: Some(&nginx_path(&state.key_file)),
                ipv6,
                http2_on,
                ..base
            })
        })?;
        nginx_reload(&nginx.bin)?;
        finish(req, &state, inserted_main)
    } else if reuse_cert {
        publish(&|ipv6, http2_on| {
            render(&RenderOpts {
                cert: Some(&nginx_path(&state.cert_file)),
                key: Some(&nginx_path(&state.key_file)),
                ipv6,
                http2_on,
                ..base
            })
        })?;
        nginx_reload(&nginx.bin)?;
        finish(req, &state, inserted_main)
    } else {
        publish(&|ipv6, http2_on| {
            render(&RenderOpts {
                cert: None,
                key: None,
                ipv6,
                http2_on,
                ..base
            })
        })?;
        nginx_reload(&nginx.bin)?;
        let issued = issue_cert(req, &state).await;
        if let Err(e) = issued {
            txn.rollback()?;
            if let Err(re) = nginx_reload(&nginx.bin) {
                return Err(format!("{e}\n另外，还原配置后 reload 失败：{re}"));
            }
            return Err(e);
        }
        save_state(&state_dir, &state)?;
        publish(&|ipv6, http2_on| {
            render(&RenderOpts {
                cert: Some(&nginx_path(&state.cert_file)),
                key: Some(&nginx_path(&state.key_file)),
                ipv6,
                http2_on,
                ..base
            })
        })?;
        nginx_reload(&nginx.bin)?;
        finish(req, &state, inserted_main)
    }
}

fn finish(req: &HttpsRequest, state: &HttpsState, inserted_main: bool) -> Result<(), String> {
    save_state(&state_dir_of(state), state)?;
    if !state.external_cert && !req.no_schedule {
        match install_schedule(&state.nginx_bin, state) {
            Ok(msg) => println!("{msg}"),
            Err(e) => println!(
                "证书已经装好，但没有写上自动续期任务：{e}\n以后可以手动运行：syncnotes-server https renew --state-dir {}",
                state_dir_of(state).display()
            ),
        }
    } else if state.external_cert {
        println!("用的是已有证书，SyncNotes 不会替它续期。");
    }
    if let Some(port) = tighten_bind() {
        println!("已把 SyncNotes 改为只监听 127.0.0.1:{port}，并尝试重启服务。公网不再直接访问 {port}。");
    }
    if inserted_main {
        println!("在 nginx.conf 的 http 段加了一行 include。原文件备份为同目录的 .syncnotes-bak。");
    }
    if state.directory_url.contains("staging") {
        println!("这是 Let's Encrypt 测试证书，浏览器不会信任。确认流程没问题后，去掉 --staging 再运行一次。");
    }
    println!();
    println!("HTTPS 已就绪。");
    println!("客户端服务器地址填写：https://{}", state.domain);
    println!("可以先检查：curl https://{}/health", state.domain);
    Ok(())
}

fn state_dir_of(state: &HttpsState) -> PathBuf {
    state
        .account_file
        .parent()
        .unwrap_or(Path::new("."))
        .to_path_buf()
}

async fn renew(req: &HttpsRequest) -> Result<(), String> {
    let dir = req.state_dir.clone().unwrap_or_else(default_state_dir);
    let state = load_state(&dir)?;
    if state.external_cert {
        println!("当前用的是已有证书，不需要 SyncNotes 续期。");
        return Ok(());
    }
    if !req.force && cert_still_good(&state.cert_file, RENEW_WITHIN_SECS) {
        println!("证书还有超过 30 天，不续期。");
        return Ok(());
    }
    if !state.conf_file.is_file() {
        return Err(format!(
            "找不到 Nginx 配置 {}。请重新运行 https --domain {}",
            state.conf_file.display(),
            state.domain
        ));
    }
    println!("正在续期 {} …", state.domain);
    issue_cert(req, &state).await?;
    nginx_test(&state.nginx_bin)?;
    nginx_reload(&state.nginx_bin)?;
    println!("已续期。客户端不用改，地址仍是 https://{}", state.domain);
    Ok(())
}

async fn issue_cert(req: &HttpsRequest, state: &HttpsState) -> Result<(), String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let directory = state.directory_url.clone();
    let account = load_or_create_account(&state.account_file, state.email.as_deref(), &directory).await?;
    let identifiers = [Identifier::Dns(state.domain.clone())];
    let mut order = account
        .new_order(&NewOrder::new(&identifiers))
        .await
        .map_err(|e| format!("创建证书订单失败: {e}"))?;

    {
        let mut authorizations = order.authorizations();
        while let Some(result) = authorizations.next().await {
            let mut authz = result.map_err(|e| format!("读取验证信息失败: {e}"))?;
            match authz.status {
                AuthorizationStatus::Pending => {}
                AuthorizationStatus::Valid => continue,
                other => return Err(format!("域名验证状态异常: {other:?}")),
            }
            let mut challenge = authz
                .challenge(ChallengeType::Http01)
                .ok_or("Let's Encrypt 没有提供 HTTP-01 验证")?;
            let token = challenge.token.clone();
            let body = challenge.key_authorization().as_str().to_string();
            write_challenge(&state.webroot, &token, &body)?;
            if !req.no_preflight {
                preflight(&state.domain, &token, &body)?;
            }
            challenge
                .set_ready()
                .await
                .map_err(|e| format!("提交域名验证失败: {e}"))?;
        }
    }

    let policy = RetryPolicy::new()
        .initial_delay(Duration::from_secs(2))
        .timeout(Duration::from_secs(180));
    let status = order
        .poll_ready(&policy)
        .await
        .map_err(|e| format!("等待域名验证失败: {e}"))?;
    if status != OrderStatus::Ready {
        return Err(format!(
            "域名验证没有通过（{status:?}）。请确认 {} 的 DNS 指向这台机器，并且公网 80 端口能访问到这台 Nginx。",
            state.domain
        ));
    }
    let key_pem = order
        .finalize()
        .await
        .map_err(|e| format!("提交证书请求失败: {e}"))?;
    let cert_pem = order
        .poll_certificate(&policy)
        .await
        .map_err(|e| format!("下载证书失败: {e}"))?;
    if let Some(parent) = state.cert_file.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("创建证书目录失败: {e}"))?;
    }
    write_secret(&state.key_file, &key_pem)?;
    write_secret(&state.cert_file, &cert_pem)?;
    Ok(())
}

async fn load_or_create_account(
    path: &Path,
    email: Option<&str>,
    directory_url: &str,
) -> Result<Account, String> {
    if path.is_file() {
        let raw = fs::read_to_string(path).map_err(|e| format!("读取 ACME 账号失败: {e}"))?;
        if let Ok(stored) = serde_json::from_str::<StoredAccount>(&raw) {
            if stored.directory_url == directory_url {
                return Account::builder()
                    .map_err(|e| format!("初始化 ACME 失败: {e}"))?
                    .from_credentials(stored.credentials)
                    .await
                    .map_err(|e| {
                        format!(
                            "恢复 ACME 账号失败: {e}。可以删掉 {} 后重试。",
                            path.display()
                        )
                    });
            }
        }
    }
    let mailto = email.map(|e| format!("mailto:{e}"));
    let contact_refs: Vec<&str> = mailto.iter().map(String::as_str).collect();
    let (account, creds) = Account::builder()
        .map_err(|e| format!("初始化 ACME 失败: {e}"))?
        .create(
            &NewAccount {
                contact: &contact_refs,
                terms_of_service_agreed: true,
                only_return_existing: false,
            },
            directory_url.to_string(),
            None,
        )
        .await
        .map_err(|e| format!("注册 Let's Encrypt 账号失败: {e}"))?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(&StoredAccount {
        directory_url: directory_url.to_string(),
        credentials: creds,
    })
    .map_err(|e| e.to_string())?;
    write_secret(path, &json)?;
    Ok(account)
}

fn write_challenge(webroot: &Path, token: &str, body: &str) -> Result<(), String> {
    if token.is_empty()
        || !token
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("验证令牌不合法".into());
    }
    let path = challenge_path(webroot, token);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("创建验证目录失败: {e}"))?;
    }
    fs::write(&path, body).map_err(|e| format!("写入验证文件失败: {e}"))?;
    Ok(())
}

fn challenge_path(webroot: &Path, token: &str) -> PathBuf {
    webroot.join(".well-known").join("acme-challenge").join(token)
}

fn preflight(domain: &str, token: &str, expect: &str) -> Result<(), String> {
    let addr = "127.0.0.1:80"
        .to_socket_addrs()
        .map_err(|e| e.to_string())?
        .next()
        .ok_or("无法解析 127.0.0.1")?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_secs(3)).map_err(|e| {
        format!("无法连接本机 80 端口（{e}）。Nginx 需要正在监听 80，Let's Encrypt 才能验证域名。")
    })?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(3))).ok();
    let req = format!(
        "GET /.well-known/acme-challenge/{token} HTTP/1.0\r\nHost: {domain}\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(req.as_bytes())
        .map_err(|e| format!("预检请求失败: {e}"))?;
    let mut buf = String::new();
    stream
        .read_to_string(&mut buf)
        .map_err(|e| format!("读取预检响应失败: {e}"))?;
    let mut parts = buf.splitn(2, "\r\n\r\n");
    let head = parts.next().unwrap_or("");
    let body = parts.next().unwrap_or("");
    let status = head.lines().next().unwrap_or("");
    if !status.contains(" 200") {
        let preview: String = status.chars().take(160).collect();
        return Err(format!(
            "本机预检没有得到 200（{preview}）。还没有向 Let's Encrypt 提交。请确认 Nginx 正在监听 80，且没有别的 default_server 抢走 {domain}。"
        ));
    }
    if body.trim() != expect.trim() {
        return Err("验证文件内容不对。可能有另一个站点的 server_name 和这个域名冲突。".into());
    }
    Ok(())
}

fn feature_order(prefer_http2_on: bool) -> [(bool, bool); 4] {
    if prefer_http2_on {
        [(true, true), (true, false), (false, true), (false, false)]
    } else {
        [(true, false), (false, false), (true, true), (false, true)]
    }
}

#[derive(Clone, Copy)]
struct RenderOpts<'a> {
    domain: &'a str,
    upstream: &'a str,
    webroot: &'a str,
    cert: Option<&'a str>,
    key: Option<&'a str>,
    ipv6: bool,
    http2_on: bool,
}

fn render(o: &RenderOpts<'_>) -> String {
    let mut out = String::new();
    out.push_str(&format!("{MANAGED_MARK} {}\n", o.domain));
    out.push_str("# 由 syncnotes-server https 生成。删除本文件即可去掉这个站点。\n");
    if o.cert.is_some() {
        out.push_str("map $http_upgrade $syncnotes_upgrade {\n");
        out.push_str("    default upgrade;\n");
        out.push_str("    ''      close;\n");
        out.push_str("}\n\n");
    }
    out.push_str("server {\n");
    out.push_str("    listen 80;\n");
    if o.ipv6 {
        out.push_str("    listen [::]:80;\n");
    }
    out.push_str(&format!("    server_name {};\n\n", o.domain));
    out.push_str("    location ^~ /.well-known/acme-challenge/ {\n");
    out.push_str("        default_type \"text/plain\";\n");
    out.push_str(&format!("        root {};\n", o.webroot));
    out.push_str("    }\n\n");
    out.push_str("    location / {\n");
    if o.cert.is_some() {
        out.push_str("        return 301 https://$host$request_uri;\n");
    } else {
        out.push_str("        default_type \"text/plain\";\n");
        out.push_str("        return 200 'syncnotes certificate pending';\n");
    }
    out.push_str("    }\n");
    out.push_str("}\n");

    if let (Some(cert), Some(key)) = (o.cert, o.key) {
        out.push_str("\nserver {\n");
        if o.http2_on {
            out.push_str("    listen 443 ssl;\n");
            if o.ipv6 {
                out.push_str("    listen [::]:443 ssl;\n");
            }
            out.push_str("    http2 on;\n");
        } else {
            out.push_str("    listen 443 ssl http2;\n");
            if o.ipv6 {
                out.push_str("    listen [::]:443 ssl http2;\n");
            }
        }
        out.push_str(&format!("    server_name {};\n\n", o.domain));
        out.push_str(&format!("    ssl_certificate {cert};\n"));
        out.push_str(&format!("    ssl_certificate_key {key};\n"));
        out.push_str("    ssl_protocols TLSv1.2 TLSv1.3;\n");
        out.push_str("    client_max_body_size 128m;\n\n");
        out.push_str("    location / {\n");
        out.push_str(&format!("        proxy_pass http://{};\n", o.upstream));
        out.push_str("        proxy_http_version 1.1;\n");
        out.push_str("        proxy_set_header Host $host;\n");
        out.push_str("        proxy_set_header X-Real-IP $remote_addr;\n");
        out.push_str("        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n");
        out.push_str("        proxy_set_header X-Forwarded-Proto https;\n");
        out.push_str("        proxy_set_header Upgrade $http_upgrade;\n");
        out.push_str("        proxy_set_header Connection $syncnotes_upgrade;\n");
        out.push_str("        proxy_read_timeout 3600s;\n");
        out.push_str("        proxy_send_timeout 3600s;\n");
        out.push_str("    }\n");
        out.push_str("}\n");
    }
    out
}

fn ensure_drop_dir(
    nginx: &NginxInfo,
    main: &str,
    block: &HttpBlock,
    includes: &[String],
) -> Result<(PathBuf, bool), String> {
    let mut dirs: Vec<(i32, String)> = includes.iter().filter_map(|p| glob_dir(p)).filter_map(|dir| {
        let score = drop_score(&dir);
        if score < 0 {
            None
        } else {
            Some((score, dir))
        }
    }).collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    if let Some((_, dir)) = dirs.first() {
        fs::create_dir_all(dir).map_err(|e| format!("创建 {dir} 失败: {e}"))?;
        return Ok((PathBuf::from(dir), false));
    }

    let dir = nginx.conf.parent().unwrap_or(nginx.prefix.as_path()).join("conf.d");
    fs::create_dir_all(&dir).map_err(|e| format!("创建 {} 失败: {e}", dir.display()))?;
    let glob = format!("{}/*.conf", nginx_path(&dir));
    if block.includes.iter().any(|p| resolve_include(&nginx.prefix, p) == glob)
        || main.contains(&glob)
    {
        return Ok((dir, false));
    }
    let bak = nginx.conf.with_file_name(format!(
        "{}.syncnotes-bak",
        nginx.conf.file_name().unwrap_or_default().to_string_lossy()
    ));
    fs::copy(&nginx.conf, &bak)
        .map_err(|e| format!("备份 {} 失败: {e}", nginx.conf.display()))?;
    let updated = insert_include(main, block.open_brace, &glob);
    fs::write(&nginx.conf, &updated)
        .map_err(|e| format!("修改 {} 失败: {e}", nginx.conf.display()))?;
    if let Err(e) = nginx_test(&nginx.bin) {
        let _ = fs::copy(&bak, &nginx.conf);
        return Err(format!(
            "无法把 include 加进 nginx.conf，已还原备份。\n{e}"
        ));
    }
    Ok((dir, true))
}

fn scan_conflicts(
    main_conf: &Path,
    includes: &[String],
    our_file: &Path,
    domain: &str,
) -> Result<(), String> {
    let mut files = vec![main_conf.to_path_buf()];
    for inc in includes {
        files.extend(expand_include(inc));
    }
    for file in files {
        if paths_equal(&file, our_file) {
            continue;
        }
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        if is_our_managed(&text, domain) {
            continue;
        }
        if server_names(&text).iter().any(|n| n == domain) {
            return Err(format!(
                "{domain} 已经写在 {} 里。SyncNotes 不会改你现有的网站。请换一个域名，或先在 Nginx 里去掉这个 server_name。",
                file.display()
            ));
        }
    }
    Ok(())
}

fn install_schedule(_nginx_bin: &Path, state: &HttpsState) -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| format!("找不到当前程序路径: {e}"))?;
    let dir = state_dir_of(state);
    #[cfg(windows)]
    {
        return install_schedule_windows(&exe, &dir);
    }
    #[cfg(not(windows))]
    {
        install_schedule_unix(&exe, &dir)
    }
}

#[cfg(not(windows))]
fn install_schedule_unix(exe: &Path, dir: &Path) -> Result<String, String> {
    let path = PathBuf::from("/etc/cron.d/syncnotes-https");
    let body = format!(
        "# SyncNotes HTTPS 续期。由 syncnotes-server 生成，删除本文件即停止自动续期。\n\
         SHELL=/bin/sh\n\
         PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n\
         17 3 * * * root {} https renew --state-dir {}\n",
        sh_quote(&exe.to_string_lossy()),
        sh_quote(&dir.to_string_lossy())
    );
    fs::write(&path, body).map_err(|e| {
        format!("没有权限写 {}（{e}）。请用 root 再运行一次，或自己每天执行上面的续期命令。", path.display())
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o644));
    }
    Ok(format!("已安装每天 03:17 的续期任务：{}", path.display()))
}

#[cfg(windows)]
fn install_schedule_windows(exe: &Path, dir: &Path) -> Result<String, String> {
    let tr = schtasks_tr(exe, dir);
    let out = Command::new("schtasks")
        .args([
            "/Create",
            "/F",
            "/TN",
            "SyncNotesHttpsRenew",
            "/SC",
            "DAILY",
            "/ST",
            "03:17",
            "/TR",
            &tr,
        ])
        .output()
        .map_err(|e| format!("无法运行 schtasks: {e}"))?;
    if out.status.success() {
        Ok("已安装每天 03:17 的续期任务：计划任务 SyncNotesHttpsRenew".into())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        Err(format!(
            "schtasks 失败：{err}请用管理员运行，或手动添加计划任务：{tr}"
        ))
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn schtasks_tr(exe: &Path, dir: &Path) -> String {
    format!(
        "\"{}\" https renew --state-dir \"{}\"",
        exe.display(),
        dir.display()
    )
}

fn tighten_bind() -> Option<u16> {
    #[cfg(not(windows))]
    {
        let path = Path::new("/etc/syncnotes/syncnotes.env");
        let text = fs::read_to_string(path).ok()?;
        let mut port = None;
        let mut changed = false;
        let mut lines: Vec<String> = Vec::new();
        for line in text.lines() {
            if let Some(value) = line.trim().strip_prefix("SYNCNOTES_BIND=") {
                let value = value.trim().trim_matches('"');
                if let Some((host, p)) = split_host_port(value) {
                    if host == "0.0.0.0" || host == "*" || host == "::" || host == "[::]" {
                        if let Ok(n) = p.parse::<u16>() {
                            port = Some(n);
                            changed = true;
                            lines.push(format!("SYNCNOTES_BIND=127.0.0.1:{n}"));
                            continue;
                        }
                    }
                }
            }
            lines.push(line.to_string());
        }
        if !changed {
            return None;
        }
        let mut out = lines.join("\n");
        if text.ends_with('\n') {
            out.push('\n');
        }
        fs::write(path, out).ok()?;
        let _ = Command::new("systemctl")
            .args(["try-restart", "syncnotes"])
            .status();
        port
    }
    #[cfg(windows)]
    {
        None
    }
}

fn probe_nginx(explicit: Option<&Path>) -> Result<NginxInfo, String> {
    let bin = find_nginx(explicit)?;
    let output = Command::new(&bin)
        .arg("-V")
        .output()
        .map_err(|e| format!("无法运行 {}：{e}", bin.display()))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let mut info = parse_nginx_v(&text)?;
    info.bin = bin;
    if !info.conf.is_file() {
        return Err(format!("找不到 Nginx 主配置 {}", info.conf.display()));
    }
    Ok(info)
}

fn find_nginx(explicit: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(p) = explicit {
        if p.is_file() {
            return Ok(p.to_path_buf());
        }
        return Err(format!("找不到指定的 nginx：{}", p.display()));
    }
    let name = if cfg!(windows) { "nginx.exe" } else { "nginx" };
    if let Some(p) = find_on_path(name) {
        return Ok(p);
    }
    if !cfg!(windows) {
        if let Some(p) = find_on_path("nginx") {
            return Ok(p);
        }
    }
    let candidates = [
        "/usr/sbin/nginx",
        "/usr/local/sbin/nginx",
        "/usr/local/nginx/sbin/nginx",
        "/usr/bin/nginx",
    ];
    for c in candidates {
        let p = PathBuf::from(c);
        if p.is_file() {
            return Ok(p);
        }
    }
    Err("没有找到 nginx。如果已经安装，请用 --nginx 指出 nginx 程序的路径。".into())
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&var) {
        let p = dir.join(name);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

fn nginx_test(bin: &Path) -> Result<(), String> {
    nginx_run(bin, &["-t"])
}

fn nginx_reload(bin: &Path) -> Result<(), String> {
    nginx_run(bin, &["-s", "reload"]).map_err(|e| {
        format!("nginx -s reload 失败。配置如果已通过 nginx -t，请先确认 Nginx 在运行，然后重新执行同一条命令。\n{e}")
    })
}

fn nginx_run(bin: &Path, args: &[&str]) -> Result<(), String> {
    let out = Command::new(bin)
        .args(args)
        .output()
        .map_err(|e| format!("无法运行 {}：{e}", bin.display()))?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let stdout = String::from_utf8_lossy(&out.stdout);
        Err(format!("{err}{stdout}").trim().to_string())
    }
}

fn default_state_dir() -> PathBuf {
    if let Some(p) = std::env::var_os("SYNCNOTES_HTTPS_DIR") {
        return PathBuf::from(p);
    }
    #[cfg(windows)]
    {
        if let Some(p) = std::env::var_os("ProgramData") {
            return PathBuf::from(p).join("SyncNotes").join("https");
        }
        return PathBuf::from(r"C:\ProgramData\SyncNotes\https");
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/var/lib/syncnotes/https")
    }
}

fn load_state(dir: &Path) -> Result<HttpsState, String> {
    let path = dir.join("state.json");
    let raw = fs::read_to_string(&path).map_err(|_| {
        format!(
            "还没有配置过 HTTPS（找不到 {}）。请先运行：syncnotes-server https --domain 你的域名",
            path.display()
        )
    })?;
    serde_json::from_str(&raw).map_err(|e| format!("状态文件损坏: {e}"))
}

fn save_state(dir: &Path, state: &HttpsState) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let raw = serde_json::to_string_pretty(state).map_err(|e| e.to_string())?;
    fs::write(dir.join("state.json"), raw).map_err(|e| format!("保存状态失败: {e}"))
}

fn cert_still_good(path: &Path, within_secs: i64) -> bool {
    let Ok(pem) = fs::read(path) else {
        return false;
    };
    let Ok(not_after) = cert_not_after(&pem) else {
        return false;
    };
    not_after - now_unix() > within_secs
}

fn cert_not_after(pem: &[u8]) -> Result<i64, String> {
    let (_, pem) = x509_parser::pem::parse_x509_pem(pem).map_err(|e| format!("{e:?}"))?;
    let cert = pem.parse_x509().map_err(|e| format!("{e:?}"))?;
    Ok(cert.validity().not_after.timestamp())
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn write_secret(path: &Path, data: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.create(true).write(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut file = opts
            .open(&tmp)
            .map_err(|e| format!("写入 {} 失败: {e}", tmp.display()))?;
        file.write_all(data.as_bytes())
            .map_err(|e| format!("写入 {} 失败: {e}", tmp.display()))?;
    }
    fs::rename(&tmp, path).map_err(|e| format!("写入 {} 失败: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn canonicalize_existing(path: &Path) -> Result<PathBuf, String> {
    path.canonicalize()
        .map_err(|e| format!("{} 无法读取: {e}", path.display()))
}

fn normalize_domain(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("请指定 --domain，例如 --domain notes.example.com".into());
    }
    let mut s = raw.to_string();
    if let Some(rest) = s.strip_prefix("https://") {
        s = rest.to_string();
    } else if let Some(rest) = s.strip_prefix("http://") {
        s = rest.to_string();
    }
    s = s.trim_end_matches('/').to_string();
    if s.contains('/') || s.contains(' ') || s.contains('\\') {
        return Err("域名不能带路径".into());
    }
    if let Some((host, port)) = split_host_port(&s) {
        if port.chars().all(|c| c.is_ascii_digit()) && !host.is_empty() {
            return Err("不要写端口。HTTPS 使用 443，由 Nginx 监听。".into());
        }
    }
    if !s.is_ascii() {
        return Err("请使用英文域名，或它的 punycode（xn-- 开头）。".into());
    }
    let s = s.to_ascii_lowercase();
    if s.parse::<std::net::IpAddr>().is_ok() {
        return Err("Let's Encrypt 不能给 IP 地址签发证书。".into());
    }
    if s.len() > 253 || !s.contains('.') || s.starts_with('.') || s.ends_with('.') {
        return Err("域名格式不正确".into());
    }
    for label in s.split('.') {
        if label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err("域名格式不正确".into());
        }
    }
    Ok(s)
}

fn normalize_upstream(raw: &str) -> Result<String, String> {
    let mut s = raw.trim().trim_end_matches('/').to_string();
    if let Some(rest) = s.strip_prefix("https://") {
        s = rest.to_string();
    } else if let Some(rest) = s.strip_prefix("http://") {
        s = rest.to_string();
    }
    if s.contains('/') {
        return Err("反代地址不要带路径，例如 127.0.0.1:7700".into());
    }
    let (host, port) = split_host_port(&s).ok_or("反代地址要写成 主机:端口，例如 127.0.0.1:7700")?;
    let port_n: u16 = port.parse().map_err(|_| "反代端口不正确".to_string())?;
    if port_n == 0 {
        return Err("反代端口不正确".into());
    }
    if host.is_empty() {
        return Err("反代地址缺少主机".into());
    }
    let host_out = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    Ok(format!("{host_out}:{port_n}"))
}

fn split_host_port(s: &str) -> Option<(&str, &str)> {
    if let Some(rest) = s.strip_prefix('[') {
        let (host, port) = rest.split_once("]:")?;
        return Some((host, port));
    }
    s.rsplit_once(':')
}

fn check_email(email: &str) -> Result<(), String> {
    if email.contains(' ') || !email.contains('@') || email.starts_with('@') || email.ends_with('@')
    {
        return Err("邮箱格式不正确".into());
    }
    Ok(())
}

fn parse_nginx_v(text: &str) -> Result<NginxInfo, String> {
    let version = parse_version(text).ok_or("无法识别 nginx 版本（nginx -V 的输出异常）")?;
    let conf = arg_value(text, "conf-path").ok_or("nginx -V 里没有 --conf-path")?;
    let prefix = arg_value(text, "prefix").unwrap_or_else(|| {
        Path::new(&conf)
            .parent()
            .unwrap_or(Path::new("."))
            .display()
            .to_string()
    });
    Ok(NginxInfo {
        bin: PathBuf::new(),
        version,
        prefix: PathBuf::from(prefix),
        conf: PathBuf::from(conf),
    })
}

fn parse_version(text: &str) -> Option<(u32, u32, u32)> {
    let mut rest = text;
    while let Some(i) = rest.find("nginx/") {
        let after = &rest[i + "nginx/".len()..];
        if after.starts_with(|c: char| c.is_ascii_digit()) {
            let ver: String = after
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect();
            let mut nums = ver.split('.');
            let major = nums.next()?.parse().ok()?;
            let minor = nums.next()?.parse().ok()?;
            let patch = nums.next().and_then(|s| s.parse().ok()).unwrap_or(0);
            return Some((major, minor, patch));
        }
        rest = after;
    }
    None
}

fn http2_directive(version: (u32, u32, u32)) -> bool {
    version >= (1, 25, 1)
}

fn arg_value(text: &str, key: &str) -> Option<String> {
    let pat = format!("--{key}=");
    let rest = &text[text.find(&pat)? + pat.len()..];
    if let Some(stripped) = rest.strip_prefix('"') {
        let end = stripped.find('"')?;
        Some(stripped[..end].to_string())
    } else if let Some(stripped) = rest.strip_prefix('\'') {
        let end = stripped.find('\'')?;
        Some(stripped[..end].to_string())
    } else {
        Some(rest.split_whitespace().next()?.trim_matches(',').to_string())
    }
}

fn parse_http(src: &str) -> Result<HttpBlock, String> {
    let b = src.as_bytes();
    let mut i = 0usize;
    let mut depth = 0i32;
    let mut open_brace = None;
    let mut includes = Vec::new();
    let mut quote: Option<u8> = None;
    while i < b.len() {
        let c = b[i];
        if let Some(q) = quote {
            if c == b'\\' {
                i = i.saturating_add(2);
                continue;
            }
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        if c == b'#' {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'"' || c == b'\'' {
            quote = Some(c);
            i += 1;
            continue;
        }
        if c == b'{' {
            if depth == 0 && open_brace.is_none() && keyword_before(b, i) == "http" {
                open_brace = Some(i);
            }
            depth += 1;
            i += 1;
            continue;
        }
        if c == b'}' {
            depth -= 1;
            if depth < 0 {
                return Err("nginx 配置的括号不匹配".into());
            }
            i += 1;
            continue;
        }
        if open_brace.is_some() && depth == 1 && (c.is_ascii_alphabetic() || c == b'_') {
            let start = i;
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            if &src[start..i] == "include" {
                skip_ws(b, &mut i);
                includes.push(take_arg(src, &mut i)?);
            }
            continue;
        }
        i += 1;
    }
    Ok(HttpBlock {
        open_brace: open_brace.ok_or("没有找到 http { }，无法安全地添加站点")?,
        includes,
    })
}

fn keyword_before(b: &[u8], brace: usize) -> String {
    let mut j = brace;
    while j > 0 && b[j - 1].is_ascii_whitespace() {
        j -= 1;
    }
    let end = j;
    while j > 0 && (b[j - 1].is_ascii_alphanumeric() || b[j - 1] == b'_') {
        j -= 1;
    }
    String::from_utf8_lossy(&b[j..end]).into_owned()
}

fn skip_ws(b: &[u8], i: &mut usize) {
    while *i < b.len() && b[*i].is_ascii_whitespace() {
        *i += 1;
    }
}

fn take_arg(src: &str, i: &mut usize) -> Result<String, String> {
    let b = src.as_bytes();
    if *i >= b.len() {
        return Err("include 缺少路径".into());
    }
    let arg = if b[*i] == b'"' || b[*i] == b'\'' {
        let q = b[*i];
        *i += 1;
        let start = *i;
        while *i < b.len() && b[*i] != q {
            *i += 1;
        }
        if *i >= b.len() {
            return Err("include 的引号没有结束".into());
        }
        let s = src[start..*i].to_string();
        *i += 1;
        s
    } else {
        let start = *i;
        while *i < b.len() && !b[*i].is_ascii_whitespace() && b[*i] != b';' {
            *i += 1;
        }
        src[start..*i].to_string()
    };
    while *i < b.len() && b[*i] != b';' {
        *i += 1;
    }
    if *i < b.len() && b[*i] == b';' {
        *i += 1;
    }
    if arg.is_empty() {
        return Err("include 缺少路径".into());
    }
    Ok(arg)
}

fn insert_include(src: &str, open_brace: usize, glob: &str) -> String {
    let line = format!("\n    include {glob};");
    let mut out = String::new();
    out.push_str(&src[..=open_brace]);
    out.push_str(&line);
    out.push_str(&src[open_brace + 1..]);
    out
}

fn resolve_include(prefix: &Path, pattern: &str) -> String {
    let p = pattern.replace('\\', "/");
    let absolute = p.starts_with('/') || (p.len() >= 3 && p.as_bytes().get(1) == Some(&b':'));
    if absolute {
        p
    } else {
        nginx_path(&prefix.join(p))
    }
}

fn glob_dir(pattern: &str) -> Option<String> {
    if !pattern.contains('*') {
        return None;
    }
    let p = pattern.replace('\\', "/");
    let without = p.split('*').next().unwrap_or("");
    let dir = without.rsplit_once('/').map(|(d, _)| d).unwrap_or("");
    if dir.is_empty() {
        None
    } else {
        Some(dir.to_string())
    }
}

fn drop_score(dir: &str) -> i32 {
    let d = dir.replace('\\', "/").to_ascii_lowercase();
    if d.contains("/modules") || d.ends_with("/modules") {
        -100
    } else if d.contains("conf.d") {
        100
    } else if d.contains("sites-enabled") {
        80
    } else if d.contains("vhost") {
        60
    } else {
        10
    }
}

fn expand_include(pattern: &str) -> Vec<PathBuf> {
    let pattern = pattern.replace('\\', "/");
    if !pattern.contains('*') {
        let p = PathBuf::from(&pattern);
        return if p.is_file() { vec![p] } else { Vec::new() };
    }
    let Some((dir, pat)) = pattern.rsplit_once('/') else {
        return Vec::new();
    };
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for ent in rd.flatten() {
        let name = ent.file_name().to_string_lossy().into_owned();
        if name_matches(pat, &name) && ent.path().is_file() {
            out.push(ent.path());
        }
    }
    out.sort();
    out
}

fn name_matches(pat: &str, name: &str) -> bool {
    if pat == "*" {
        return true;
    }
    if let Some(suf) = pat.strip_prefix('*') {
        return name.ends_with(suf);
    }
    if let Some(pre) = pat.strip_suffix('*') {
        return name.starts_with(pre);
    }
    pat == name
}

fn server_names(src: &str) -> Vec<String> {
    let b = src.as_bytes();
    let mut i = 0usize;
    let mut quote: Option<u8> = None;
    let mut names = Vec::new();
    while i < b.len() {
        let c = b[i];
        if let Some(q) = quote {
            if c == b'\\' {
                i = i.saturating_add(2);
                continue;
            }
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        if c == b'#' {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'"' || c == b'\'' {
            quote = Some(c);
            i += 1;
            continue;
        }
        if c.is_ascii_alphabetic() || c == b'_' {
            let start = i;
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            if &src[start..i] == "server_name" {
                while i < b.len() && b[i] != b';' && b[i] != b'{' && b[i] != b'#' {
                    skip_ws(b, &mut i);
                    if i >= b.len() || b[i] == b';' || b[i] == b'#' {
                        break;
                    }
                    let tstart = i;
                    while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b';' {
                        i += 1;
                    }
                    let token = src[tstart..i].trim_matches(|c| c == '"' || c == '\'' || c == ';');
                    if !token.is_empty() {
                        names.push(token.to_ascii_lowercase());
                    }
                }
            }
            continue;
        }
        i += 1;
    }
    names
}

fn is_our_managed(text: &str, domain: &str) -> bool {
    text.lines()
        .take(2)
        .any(|l| l.trim() == format!("{MANAGED_MARK} {domain}"))
}

fn paths_equal(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

fn panel_of(nginx: &NginxInfo, includes: &[String]) -> Option<&'static str> {
    let mut paths = vec![
        nginx.conf.display().to_string(),
        nginx.prefix.display().to_string(),
        nginx.bin.display().to_string(),
    ];
    paths.extend(includes.iter().cloned());
    paths.iter().find_map(|p| panel_name(p))
}

fn panel_name(path: &str) -> Option<&'static str> {
    let p = path.replace('\\', "/").to_ascii_lowercase();
    if p.contains("/www/server/panel") || p.contains("/www/server/nginx") {
        Some("宝塔")
    } else if p.contains("1panel") {
        Some("1Panel")
    } else {
        None
    }
}

fn panel_message(kind: &str, domain: &str, upstream: &str) -> String {
    format!(
        "检测到{kind}的 Nginx。面板会覆盖直接写入的配置，所以没有改任何文件。\n\
         请在面板里新建网站 {domain}：\n\
         · 反向代理到 http://{upstream}\n\
         · 申请 Let's Encrypt 证书\n\
         · 打开 WebSocket（Upgrade 和 Connection 头）\n\
         · 上传大小至少 128m\n\
         然后在客户端填写 https://{domain}\n\
         如果确定要绕过面板直接写配置，再加上 --allow-panel。"
    )
}

fn nginx_path(path: &Path) -> String {
    let s = path.to_string_lossy().replace('\\', "/");
    if s.chars().any(|c| c.is_whitespace() || c == ';') {
        format!("\"{s}\"")
    } else {
        s
    }
}

fn sh_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "/._-+".contains(c))
    {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_and_upstream() {
        assert_eq!(
            normalize_domain("https://Notes.Example.com/").unwrap(),
            "notes.example.com"
        );
        assert!(normalize_domain("notes.example.com:443").is_err());
        assert!(normalize_domain("10.0.0.1").is_err());
        assert!(normalize_domain("").is_err());
        assert_eq!(
            normalize_upstream("http://127.0.0.1:7700/").unwrap(),
            "127.0.0.1:7700"
        );
        assert_eq!(normalize_upstream("[::1]:7700").unwrap(), "[::1]:7700");
    }

    #[test]
    fn parses_nginx_version_and_paths() {
        let text = "nginx version: nginx/1.24.0\nconfigure arguments: --prefix=/etc/nginx --conf-path=/etc/nginx/nginx.conf --with-x\n";
        let info = parse_nginx_v(text).unwrap();
        assert_eq!(info.version, (1, 24, 0));
        assert!(!http2_directive(info.version));
        assert!(http2_directive((1, 25, 1)));
        assert_eq!(info.conf, PathBuf::from("/etc/nginx/nginx.conf"));
        let quoted = "configure arguments: --conf-path=\"C:/Program Files/nginx/conf/nginx.conf\" --prefix=\"C:/Program Files/nginx\" nginx/1.27.0\n";
        let info = parse_nginx_v(quoted).unwrap();
        assert_eq!(
            info.conf,
            PathBuf::from("C:/Program Files/nginx/conf/nginx.conf")
        );
    }

    #[test]
    fn http_includes_ignore_comments_and_servers() {
        let src = r#"
# http { include evil.conf; }
events {}
http {
    include mime.types;
    include /etc/nginx/conf.d/*.conf;
    include "/etc/nginx/sites-enabled/*";
    server {
        include snippets/inside.conf;
        server_name notes.example.com;
    }
}
"#;
        let block = parse_http(src).unwrap();
        assert_eq!(
            block.includes,
            vec![
                "mime.types".to_string(),
                "/etc/nginx/conf.d/*.conf".to_string(),
                "/etc/nginx/sites-enabled/*".to_string(),
            ]
        );
        assert_eq!(server_names(src), vec!["notes.example.com".to_string()]);
        let glob = "/etc/nginx/conf.d/*.conf";
        assert_eq!(glob_dir(glob).as_deref(), Some("/etc/nginx/conf.d"));
        assert!(drop_score("/etc/nginx/conf.d") > drop_score("/etc/nginx/sites-enabled"));
        assert!(drop_score("/usr/lib/nginx/modules") < 0);
    }

    #[test]
    fn insert_include_is_inside_http() {
        let src = "events {}\nhttp {\n    include mime.types;\n}\n";
        let block = parse_http(src).unwrap();
        let updated = insert_include(src, block.open_brace, "/etc/nginx/conf.d/*.conf");
        assert!(updated.contains("http {\n    include /etc/nginx/conf.d/*.conf;\n"));
        let again = parse_http(&updated).unwrap();
        assert!(again.includes.iter().any(|p| p.contains("conf.d")));
    }

    #[test]
    fn render_has_websocket_and_challenge() {
        let text = render(&RenderOpts {
            domain: "notes.example.com",
            upstream: "127.0.0.1:7700",
            webroot: "/var/lib/syncnotes/https/webroot",
            cert: Some("/certs/fullchain.pem"),
            key: Some("/certs/privkey.pem"),
            ipv6: false,
            http2_on: true,
        });
        assert!(text.contains("proxy_set_header Upgrade $http_upgrade;"));
        assert!(text.contains("Connection $syncnotes_upgrade;"));
        assert!(text.contains("proxy_pass http://127.0.0.1:7700;"));
        assert!(text.contains("client_max_body_size 128m;"));
        assert!(text.contains("location ^~ /.well-known/acme-challenge/"));
        assert!(text.contains("http2 on;"));
        assert!(!text.contains("[::]"));
        assert!(is_our_managed(&text, "notes.example.com"));
    }

    #[test]
    fn conf_rollback_removes_new_file_and_restores_old() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("site.conf");
        let txn = ConfTxn::begin(&path).unwrap();
        txn.write("server { }\n").unwrap();
        assert!(path.exists());
        txn.rollback().unwrap();
        assert!(!path.exists());

        fs::write(&path, "old").unwrap();
        let txn = ConfTxn::begin(&path).unwrap();
        txn.write("new").unwrap();
        txn.rollback().unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "old");
    }

    #[test]
    fn schedule_quoting_and_panel_message() {
        assert_eq!(sh_quote("/usr/bin/syncnotes-server"), "/usr/bin/syncnotes-server");
        assert_eq!(sh_quote("/opt/my server/a"), "'/opt/my server/a'");
        let tr = schtasks_tr(Path::new(r"C:\Sync Notes\syncnotes-server.exe"), Path::new(r"C:\ProgramData\SyncNotes\https"));
        assert!(tr.contains("https renew"));
        assert!(tr.contains("--state-dir"));
        let msg = panel_message("宝塔", "notes.example.com", "127.0.0.1:7700");
        assert!(msg.contains("没有改任何文件"));
        assert!(panel_name("/www/server/nginx/sbin/nginx") == Some("宝塔"));
        assert!(panel_name("/usr/sbin/nginx").is_none());
    }

    #[tokio::test]
    async fn renew_without_state_is_a_clear_error() {
        let dir = tempfile::tempdir().unwrap();
        let err = execute(HttpsRequest {
            domain: None,
            email: None,
            upstream: "127.0.0.1:7700".into(),
            state_dir: Some(dir.path().to_path_buf()),
            nginx_bin: None,
            cert: None,
            key: None,
            staging: false,
            allow_panel: false,
            no_schedule: true,
            renew: true,
            force: false,
            no_preflight: false,
        })
        .await
        .unwrap_err();
        assert!(err.contains("还没有配置过 HTTPS"), "{err}");
    }
}
