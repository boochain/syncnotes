# SyncNotes 实时同步笔记 / 消息队列

一个可以自己部署的多设备实时同步工具：在任意一台设备上发消息、写笔记、传文件，其他设备**立即**看到。

- **客户端**：Windows / Linux / Android，同一套 Flutter 代码（Material 3 界面）
  - 桌面端：系统托盘常驻，右下角小窗口，关闭即隐藏到托盘
  - Android：独立应用，前台服务保持长连接，新内容本地通知推送（无需任何付费推送服务）
- **服务器**：Rust 编写的轻量 WebSocket 同步服务（单个可执行文件 + SQLite），可部署在自己的服务器，也可以在局域网里直接运行（支持 mDNS 自动发现）
- **离线可用**：离线时的编辑会排队保存在本地，重新连上后自动重放同步

![Linux 桌面端截图](docs/screenshots/linux-home.png)

---

## 功能概览（v0.1）

| 功能 | 说明 |
|---|---|
| 消息块 | 底部输入栏快速发送；点击复制内容 |
| 笔记块 | Markdown 编辑 / 预览，自动保存，多设备实时同步 |
| 文件块 | 上传到自己的服务器，其他设备点击下载并用系统程序打开 |
| 文件夹 | 可包含其他任意块，支持移动块到文件夹，删除时连同子块一起删除 |
| 已读状态 | **每个块可单独设置**：<br>· 按设备（默认）：每台设备独立记录已读/未读<br>· 全局：在一台设备上看过，所有设备都标为已读 |
| 实时同步 | WebSocket 推送；编辑冲突按"最后写入者获胜"处理 |
| 离线队列 | 离线编辑持久化到本地，重连后按顺序重放；同一块多次离线编辑合并为一次 |
| 登录 | 用户名 + 密码，服务端签发令牌，客户端保存令牌实现开机后自动登录 |
| 开机自启 | Windows（注册表 Run 项）、Linux（XDG autostart）、Android（开机自动启动后台同步服务） |
| 局域网 | 客户端直接填写局域网 IP:端口；登录页可一键搜索局域网服务器（mDNS） |
| 可扩展类型 | 每种块类型自己定义 显示 / 编辑 / 执行 行为，新增类型只需实现一个类并注册 |

---

## 一、部署服务器

服务器只有一个可执行文件，数据保存在一个 SQLite 文件和一个文件目录中。

### 方式 1：直接运行预编译文件（推荐）

到 [Releases](../../releases) 下载对应平台的服务器：

- `syncnotes-server-<版本>-linux-x86_64.tar.gz`（静态链接，适用于绝大多数 Linux 服务器）
- `syncnotes-server-<版本>-linux-aarch64.tar.gz`（树莓派 / ARM 服务器）
- `syncnotes-server-<版本>-windows-x86_64.zip`

压缩包内包含服务器程序、README 和 `deploy/`（systemd / Docker / Caddy 配置）。

```bash
tar xzf syncnotes-server-v0.1.1-linux-x86_64.tar.gz
cd syncnotes-server-v0.1.1-linux-x86_64
./syncnotes-server --bind 0.0.0.0:7700
```

Windows：解压 zip 后运行 `syncnotes-server.exe`。

启动后：

- 健康检查：`http://服务器IP:7700/health`
- WebSocket：`ws://服务器IP:7700/ws`

### 常用参数（也可用环境变量）

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--bind` | `SYNCNOTES_BIND` | `0.0.0.0:7700` | 监听地址 |
| `--db` | `SYNCNOTES_DB` | `syncnotes.db` | SQLite 数据库路径 |
| `--files-dir` | `SYNCNOTES_FILES` | `syncnotes-files` | 文件块的存储目录 |
| `--allow-register` | `SYNCNOTES_ALLOW_REGISTER` | `true` | 是否允许注册新用户。**建好自己的账号后建议设为 `false`** |
| `--mdns` | `SYNCNOTES_MDNS` | `true` | 是否在局域网广播 `_syncnotes._tcp` 服务 |
| `--mdns-name` | `SYNCNOTES_MDNS_NAME` | `SyncNotes` | 局域网广播名称 |

### 方式 2：systemd 常驻（Linux 服务器）

```bash
sudo useradd -r -s /usr/sbin/nologin syncnotes
sudo mkdir -p /var/lib/syncnotes && sudo chown syncnotes /var/lib/syncnotes
sudo cp syncnotes-server /usr/local/bin/syncnotes-server
sudo cp deploy/syncnotes.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now syncnotes
```

### 方式 3：Docker

```bash
cd deploy
docker compose up -d --build
```

### 公网部署建议：加 HTTPS

在服务器前面放一个反向代理（以 Caddy 为例，自动申请免费证书），参考 `deploy/Caddyfile.example`：

```
notes.example.com {
    reverse_proxy 127.0.0.1:7700
}
```

客户端服务器地址填写 `https://notes.example.com` 即可（会自动使用 `wss://`）。

> ⚠️ 不加 HTTPS 时密码和令牌以明文传输，仅建议在局域网或可信网络中使用。

### 局域网模式

在局域网任意一台电脑上运行服务器即可，客户端：

- 直接输入 `192.168.x.x:7700`；或
- 在登录页点击服务器输入框右侧的 📡 图标，自动搜索局域网中的服务器（mDNS）

Android 上若搜索不到，请直接手动填写 IP（部分路由器/系统会屏蔽组播）。

---

## 二、客户端使用

### 安装

到 [Releases](../../releases) 下载：

| 平台 | 文件 | 安装方式 |
|---|---|---|
| Windows | `SyncNotes-windows-x64.zip` | 解压后运行 `SyncNotes\syncnotes.exe`（已附带 VC++ 运行库） |
| Linux | `SyncNotes-linux-x64.tar.gz` | 解压后运行 `SyncNotes/syncnotes`（需要 GTK3；托盘需 `libayatana-appindicator3-1`） |
| Android | `SyncNotes-android.apk` | 允许"安装未知来源应用"后安装 |

### 首次登录

1. 填写服务器地址（如 `192.168.1.10:7700` 或 `https://notes.example.com`）
2. 第一次使用点击 **"没有账号？注册"**，输入用户名和密码 → **注册并登录**
3. 以后启动会使用保存的令牌**自动登录**，无需再次输入密码

### 日常使用

- **发消息**：底部输入框输入内容，回车或点 ➤ 发送
- **新建笔记 / 文件 / 文件夹**：点输入框左侧的 ⊕
- **点击块** = 执行该类型的主操作：
  - 消息：复制到剪贴板
  - 笔记：打开 Markdown 编辑器（编辑 / 预览两个标签页，自动保存）
  - 文件：下载并用系统默认程序打开（保存在 下载/SyncNotes 目录）
  - 文件夹：进入文件夹
- **长按 / 右键 / ⋮ 菜单**：编辑、标为已读/未读、切换"全局已读"、移动到文件夹、删除
- **未读标记**：未读块带蓝点并加粗；带 🌐 图标的块使用"全局已读"模式
- **顶部状态**：在线 / 连接中 / 离线（显示待同步数量）

### 设置

- **登录系统时自动启动**（桌面） / **开机自动启动后台同步**（Android）
- **启动时最小化到托盘**（桌面）
- **后台保持连接（前台服务）**（Android）：开启后通知栏会有一个常驻通知，保证新消息能及时推送
- **新内容通知**
- **新建块默认使用全局已读**
- 清除本地缓存并重新同步、退出登录

### 桌面端托盘

- 左键单击托盘图标：显示 / 隐藏窗口（窗口出现在屏幕右下角）
- 右键：显示窗口（含未读数）/ 退出
- 点击窗口关闭按钮只会隐藏到托盘，真正退出请用托盘菜单的"退出"

---

## 三、开发

```
syncnotes/
├── server/          Rust 同步服务器 (axum + tokio + SQLite)
│   ├── src/
│   │   ├── blocks.rs     块类型 / 已读模式定义
│   │   ├── protocol.rs   WebSocket 消息协议
│   │   ├── storage.rs    SQLite 持久化（LWW、序号、已读）
│   │   ├── sync.rs       WebSocket 处理 / 登录注册
│   │   └── files.rs      文件上传下载
│   └── tests/sync_tests.rs   端到端集成测试
├── app/             Flutter 客户端
│   ├── lib/
│   │   ├── models/       块模型
│   │   ├── blocks/       可扩展块类型注册表 + 内置类型
│   │   ├── sync/         同步引擎（离线队列、重连、增量追赶）
│   │   ├── platform/     托盘/窗口、自启动、通知、Android 前台服务
│   │   └── ui/           界面
│   └── test/             单元 / 组件 / 跨栈端到端测试
├── deploy/          Dockerfile、systemd、Caddy 示例
└── .github/workflows/build.yml   CI + 打 tag 自动发布
```

### 运行测试

```bash
# 服务器
cd server && cargo test

# 客户端（设置 SYNCNOTES_SERVER_BIN 后会额外运行"真实服务器 + 两个客户端"的端到端测试）
cd server && cargo build --release
cd ../app && SYNCNOTES_SERVER_BIN=../server/target/release/syncnotes-server flutter test
```

### 新增一种块类型

1. 服务器：在 `server/src/blocks.rs` 的 `BlockKind` 里加一个枚举值（旧服务器会把未知类型存为 `unknown`，不会报错）
2. 客户端：在 `app/lib/models/block.dart` 的 `BlockKind` 里加同名值
3. 实现一个 `BlockType` 子类（`buildPreview` 显示、`edit` 编辑、`execute` 执行），在 `registerBuiltinTypes()` 中注册

### 同步协议（简述）

客户端 → 服务器（JSON over WebSocket `/ws`）：

- `auth {token, device_id}`
- `upsert_block {id, kind, title, payload, parent_id, viewed_mode, client_updated_at, deleted}`
- `set_viewed {block_id, viewed}`
- `sync_since {since_seq}` — 断线重连后增量追赶
- `ping`

服务器 → 客户端：`auth_ok` / `auth_error` / `block_update {block}` / `viewed_update {block_id, viewed, device_id?, seq}` / `sync_complete {latest_seq}` / `error` / `pong`

每个用户有一个单调递增的序号 `seq`；每次变更都会分配新序号，客户端记录收到的最大序号，重连时只拉取之后的变更。删除使用墓碑（`deleted=true`），保证离线设备也能收到删除。

### 发布新版本

```bash
git tag v0.1.0 && git push origin v0.1.0
```

GitHub Actions 会自动构建 Windows / Linux / Android 客户端和三个平台的服务器，并发布到 Releases。

## 许可

MIT
