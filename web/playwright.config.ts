import { defineConfig } from '@playwright/test';

/**
 * 网页版端到端测试：真实启动一个 syncnotes-server（临时数据库）+ vite preview 静态站点，
 * 用 Chromium 走登录、笔记增删改、两个客户端实时同步、任务、日历、刷新后状态。
 * 运行：先 `cargo build --release`（server/），再 `npm run build && npm run e2e`。
 */
export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  globalSetup: './e2e/global-setup.ts',
  use: {
    baseURL: 'http://127.0.0.1:4173',
    viewport: { width: 1280, height: 800 },
    locale: 'zh-CN',
    trace: 'retain-on-failure',
  },
  webServer: {
    command: 'npx vite preview --host 127.0.0.1 --port 4173 --strictPort',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: true,
    timeout: 60_000,
  },
});
