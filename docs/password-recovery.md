# 忘记密码 / 数据救援

SyncNotes 自托管、没有邮箱，所以提供两条找回路径，**都不会改动任何笔记数据**：
重置只修改 `users.password_hash`（以及恢复码 / 强制改密标志）并吊销登录令牌；
用户 id、所有块、附件、回收站、已读状态都不变（数据没有用密码加密，也不以密码为键）。

## 1. 用户自助：恢复码

- 注册时服务器生成一次性恢复码（4 组 × 5 位 base32，100 位熵，例如 `K7QXM-2RTPA-W5NZC-H3FJD`），
  只保存 argon2 哈希。客户端只显示一次，可复制 / 保存为 txt，必须勾选「我已妥善保存」才能关闭。
- 登录页「忘记密码？」→ 用户名 + 恢复码 + 新密码 → 重置密码、所有设备退出、旧恢复码作废、显示新恢复码。
- 设置 → 账号 →「生成 / 重置恢复码」（需输入当前密码）。没有恢复码的旧账号登录后会提示一次。
- 安全：每用户 5 次 / 每 IP 20 次失败后锁 15 分钟（429）；argon2 校验，未知用户也做同样的哈希运算，
  错误提示统一（不泄露用户是否存在）；恢复码在事务中原子消费，并发重用会失败。

## 2. 管理员救援（恢复码也丢了）

```bash
sudo ./syncnotes-rescue.sh                       # 交互菜单（= syncnotes-server.sh 菜单 9）
sudo ./syncnotes-rescue.sh list-users            # 列出用户（块数、回收站、会话数、是否有恢复码）
sudo ./syncnotes-rescue.sh reset bill            # 重置密码：先自动备份数据库，再生成临时密码
sudo ./syncnotes-rescue.sh export bill bill.zip  # 导出全部数据（含回收站和附件）
sudo ./syncnotes-rescue.sh backup                # 在线备份数据库
# 也可以：sudo ./syncnotes-server.sh reset-password bill / export bill [out.zip] / list-users / backup
```

路径从 `/etc/syncnotes/syncnotes.env` 读取，命令以服务用户运行。也可以直接调用程序：

```bash
syncnotes-server admin list-users --db /opt/syncnotes/data/syncnotes.db
syncnotes-server admin reset-password bill [--password-stdin | --password X] [--no-force-change]
syncnotes-server admin export bill bill.zip --db ... --files-dir ...
syncnotes-server admin backup /root/syncnotes-backup.db
```

- `--db` / `--files-dir` 与 `SYNCNOTES_DB` / `SYNCNOTES_FILES` 环境变量同样生效。
- **服务运行中也可以执行**：数据库为 WAL 模式并设置了 busy timeout；运行中的服务器会在 15 秒内
  发现令牌已被吊销并断开旧连接。备份用 `VACUUM INTO`，是一致的快照。
- 默认生成临时密码，用户用它登录后**必须立即设置新密码**（在此之前不能同步）。
- 用户重新登录后，设备上尚未同步的离线修改会照常上传，不会丢失。

导出 zip 结构：`manifest.json`、`blocks.json`（全部块，含回收站与已彻底删除的墓碑）、
`device_views.json`（已读状态）、`markdown/*.md`（每个顶层页面/笔记一个文件，回收站在 `markdown/回收站/`）、
`files/*`（附件原文件）。

## 3. 客户端导出（服务器没了也能救）

设置 →「导出我的数据」：把本机缓存的全部块、回收站、未同步的修改（`pending_outbox.json`）、
已下载到本机的附件（在线时会补充下载）打包为 zip，格式与服务器导出相同。

截图：`docs/screenshots/recovery-*.png`（手机 390 宽 / 桌面 1280 宽，浅色 / 深色）。
