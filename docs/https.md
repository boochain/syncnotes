# HTTPS（已有 Nginx）

SyncNotes 服务器继续只听本机 `127.0.0.1:7700` 的明文 HTTP。公网的 TLS 由你已经在跑的 Nginx 终止，这样不会和现有网站抢 80/443。

Windows 和 Linux 用同一个子命令（需要管理员）：

```text
syncnotes-server https --domain notes.example.com
```

Linux 上如果用了管理脚本：

```bash
sudo ./syncnotes-server.sh https --domain notes.example.com
```

## 它做什么

1. 找到本机 Nginx（也可以 `--nginx` 指定程序路径）。
2. 只**新增**一个文件，例如 `/etc/nginx/conf.d/syncnotes-notes.example.com.conf`。不改你现有的 `server { }`。
3. 用内置的 ACME 客户端向 Let's Encrypt 申请证书。验证文件放在状态目录的 `webroot` 里，走已经开放的 80 端口。
4. 先在本机请求这个验证文件。不是 200 就不向 Let's Encrypt 提交，避免把失败次数用光。
5. 写成 443 反代：WebSocket 升级头、上传限制 128MB、读超时 1 小时。
6. 每写一次配置都先 `nginx -t`。失败就删掉刚加的文件并还原，**不 reload**。
7. 证书写在状态目录（Linux 默认 `/var/lib/syncnotes/https`，Windows 默认 `%ProgramData%\SyncNotes\https`）。私钥权限 600。
8. 安装续期：Linux 写 `/etc/cron.d/syncnotes-https`，Windows 写计划任务 `SyncNotesHttpsRenew`，每天 03:17 检查，剩余不足 30 天才续。

如果 `nginx.conf` 里没有任何 `conf.d` / `sites-enabled` 这类 include，才会在 `http {` 里加一行 include，并先把原文件备份成 `nginx.conf.syncnotes-bak`。这一行也会先过 `nginx -t`。

客户端不用更新。地址填 `https://notes.example.com`。

## 常用参数

| 参数 | 作用 |
|---|---|
| `--email you@example.com` | 可选。Let's Encrypt 到期提醒信 |
| `--cert` / `--key` | 使用已有的 fullchain 和私钥，不申请、不自动续期 |
| `--staging` | 向测试环境申请。浏览器不信任，用来试通流程 |
| `--upstream 127.0.0.1:7700` | 反代目标，默认就是这个 |
| `--state-dir 目录` | 证书和账号放哪 |
| `--nginx 路径` | nginx 程序不在 PATH 里时 |
| `--allow-panel` | 检测到宝塔 / 1Panel 时仍然写文件 |
| `--no-schedule` | 不安装续期任务 |
| `--no-preflight` | 跳过本机 80 端口预检 |
| `https renew` | 手动续期。`--force` 忽略「还没到期」 |

续期命令示例：

```bash
syncnotes-server https renew --state-dir /var/lib/syncnotes/https
```

## 不会做的事

- 不启动 Caddy，不自己监听 443。
- 不修改已有网站的配置。
- 检测到宝塔或 1Panel 时默认停下来，改由面板添加反向代理（目标 `http://127.0.0.1:7700`，打开 SSL 和 WebSocket）。面板会重写它不认识的配置文件。
- 不把笔记加密后存进数据库。这只保护传输过程。

## 事先确认

- `notes.example.com` 的 DNS 已经指向这台机器。
- 安全组 / 防火墙已经放行 80 和 443（网站本来就能打开的话，通常已经放行）。
- 7700 不要对公网开放。若 `/etc/syncnotes/syncnotes.env` 里是 `0.0.0.0`，命令会改成 `127.0.0.1` 并尝试重启服务。

机器上还没有 Nginx 时，用 `deploy/Caddyfile.example`。
