# SyncNotes 网页客户端

独立静态站点，对接已部署的 SyncNotes 服务器。完整说明见仓库 [`docs/web-client.md`](../docs/web-client.md)。

```bash
npm ci
npm test
npm run build   # 产物在 dist/，拷到 Nginx/Caddy/任意静态主机
npm run preview
```

登录页填写服务器地址即可。可在 `public/config.json` 里预填 `defaultServer`。反代示例见 `deploy/`。
