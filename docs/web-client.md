# SyncNotes 网页版

网页版是一个**独立的静态站点**，用浏览器打开，连接到你已经部署的 SyncNotes 服务器。它和服务器是两样东西：不要把网页客户端塞进 Rust 服务器进程里，也不需要在服务器上放整份 Flutter 工程。

协议、认证、传输加密（`syncnotes-seal-v1`）与原生客户端相同。登录后可同步消息、Markdown 笔记、便签画布、Notion 式页面、文件（含进度与 4 MB 分片续传）、文件夹和回收站。

从 v0.8.0 起，网页版能读取原生客户端的任务（`kind=task`）和日历（`kind=calendar`）块：任务可查看进度并勾选完成，日历只读。解析代码在 `web/src/features/tasks.ts` 和 `web/src/features/calendar.ts`，写回时保留原始 `kind` 和所有未识别的载荷字段。

## 为什么不用 Flutter web

- 网页版必须能单独放到 Nginx / Caddy / 任意静态主机，用户不必安装 Flutter。
- 原生客户端的界面正在并行修改；网页放在独立的 `web/` 目录，避免改动 `app/lib/ui`。
- 流体背景和玻璃折射在浏览器里用 WebGL + CSS `backdrop-filter` 实现，效果比把 Flutter 着色器搬到 CanvasKit 更稳、也更容易降级。

构建产物是普通的 `index.html` + JS/CSS，拷到静态目录即可。

## 构建

需要 Node.js 20 或以上：

```bash
cd web
npm ci
npm test
npm run build
```

静态文件在 `web/dist/`。本地预览：

```bash
npm run preview
```

默认开发服务器是 `http://127.0.0.1:4173`。

也可以在登录页填写服务器地址后，直接对着已运行的 `syncnotes-server` 使用。

## 部署方式

### 方式 A：网页和 API 分开（任意静态主机）

把 `web/dist/` 整目录上传到 GitHub Pages、对象存储、或另一台机器的 Nginx。用户打开网页后，在登录页填写 SyncNotes 服务器地址（如 `192.168.1.8:7700` 或 `https://notes.example.com`）。

服务器从 v0.6 起已启用宽松 CORS（`CorsLayer::permissive()`），跨域访问 `/health`、`/api/seal`、`/api/blob` 不需要再改服务端。WebSocket `/ws` 本身不受 CORS 约束。

注意：若网页是 `https://`，浏览器会拦截对明文 `http://` 服务器的请求（混合内容）。这种情况请给服务器也配 HTTPS，或改用下面的同源反代。

可选：编辑 `dist/config.json`（或构建前改 `web/public/config.json`）：

```json
{ "defaultServer": "https://notes.example.com" }
```

留空则登录页自己填；如果网页和 API 同源，客户端会自动探测 `/health`。

### 方式 B：同一域名反代（推荐公网）

一个域名对外：`/` 提供网页静态文件，`/health`、`/api/`、`/ws` 转到本机 `7700` 端口的 SyncNotes 服务器。这样没有跨域，也没有混合内容问题。示例见 `web/deploy/nginx.conf.example` 和 `web/deploy/Caddyfile.example`。

要点：

- 为 `/ws` 打开 WebSocket Upgrade
- 不要限制请求体大小（单文件最大 4 GB）
- 不要把整个上传缓冲完再转给上游（Nginx: `proxy_request_buffering off;`；Caddy: `flush_interval -1`）

### Nginx 分站点示例

只托管网页、API 在别的域名时：

```nginx
server {
    listen 443 ssl;
    server_name web.example.com;
    root /var/www/syncnotes-web;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

## 功能对照

| 功能 | 网页版 |
|---|---|
| 登录 / 注册 / 恢复码找回 / 修改密码 / 重新生成恢复码 | 有 |
| 公钥指纹记忆与变更提示 | 有 |
| 实时同步、离线队列、LWW | 有（缓存在浏览器 localStorage） |
| 消息、笔记、便签画布、页面、文件、文件夹 | 有 |
| 回收站（恢复 / 彻底删除 / 清空） | 有 |
| 文件上传下载与进度、大于 4 MB 分片续传 | 有 |
| 流体背景 + 玻璃透明度 / 折射率 | 有（WebGL，低性能可降级） |
| 任务 | 有：列表、筛选（未完成 / 逾期 / 已完成）、加权进度、组成项与子任务、勾选完成。新建和编辑组成项请用客户端 |
| 日历 | 只读：近 60 天日程（含带日期的任务）、会员订阅与下次扣款、重要日与倒数日。新建和编辑请用客户端 |
| 立即同步 / 备份 / 恢复 | 没有（浏览器本来就实时同步；备份恢复请用桌面或手机客户端） |

## 开发说明

源码全部在 `web/`。不要把网页版绑进 `server/` 的 HTTP 路由。协议实现见 `web/src/crypto/seal.ts`、`web/src/api/`、`web/src/sync/engine.ts`，并有单元测试覆盖加密往返、地址归一化和同步/回收站行为。
