// v0.8.2 设计验收：逐帧截取网页版每类弹层的进入 / 退出动画（暂停 Web Animations 并按时间步进）。
// 用法：node e2e-cards-capture.mjs <outDir> （需先 vite preview 于 4173、服务器 127.0.0.1:7711）
import { chromium } from '@playwright/test';
import fs from 'node:fs';
const out = process.argv[2] ?? '/tmp/webframes';
const ENTER = [0, 40, 80, 120, 160, 200, 240, 300, 360, 440];
const EXIT_CARD = [0, 40, 80, 120, 160, 200];
const EXIT_COVER = [30, 70, 110, 140];

const OURS = () => { window.__ours = () => document.getAnimations().filter((a) => a instanceof CSSTransition || /^(card|pop)-/.test(a.animationName ?? '')); };
async function pauseAll(p) { await p.evaluate(OURS); await p.evaluate(() => window.__ours().forEach((a) => a.pause())); }
async function seek(p, t) {
  await p.evaluate((t) => window.__ours().forEach((a) => { a.currentTime = t; }), t);
}
async function shots(p, dir, times, offset = 0, tag = '') {
  fs.mkdirSync(dir, { recursive: true });
  for (const t of times) {
    await seek(p, t);
    await p.screenshot({ path: `${dir}/${String(t + offset).padStart(3, '0')}${tag}.png` });
  }
}
async function capture(p, name, open, close) {
  await p.waitForTimeout(300);
  await open();
  await p.waitForTimeout(25);
  await pauseAll(p);
  await shots(p, `${out}/${name}-in`, ENTER);
  await p.evaluate(() => window.__ours().forEach((a) => a.finish()));
  await p.waitForTimeout(400);
  // 截退出帧期间扣住弹层的卸载定时器（200ms / 160ms），截完再放行
  await p.evaluate(() => {
    const w = window; w.__held = []; w.__origST = w.__origST ?? w.setTimeout;
    w.setTimeout = (fn, ms, ...a) => { if (ms === 200 || ms === 160) { w.__held.push(fn); return 0; } return w.__origST(fn, ms, ...a); };
  });
  await close();
  await p.waitForTimeout(25);
  await pauseAll(p);
  await shots(p, `${out}/${name}-out`, EXIT_CARD);
  await p.evaluate(() => window.__ours().forEach((a) => a.finish()));
  await p.evaluate(() => { const w = window; w.setTimeout = w.__origST; w.__held.forEach((f) => f()); w.__held = []; });
  await p.waitForTimeout(25);
  await pauseAll(p);
  await shots(p, `${out}/${name}-out`, EXIT_COVER, 200);
  await p.evaluate(() => window.__ours().forEach((a) => a.finish()));
  await p.waitForTimeout(300);
}

const b = await chromium.launch();
for (const vp of [{ tag: 'desktop', width: 1280, height: 800 }, { tag: 'phone', width: 390, height: 844 }]) {
  const p = await b.newPage({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: 1 });
  await p.goto('http://127.0.0.1:4173/');
  await p.waitForTimeout(800);
  await p.getByPlaceholder('服务器地址，例如 192.168.1.8:7700').fill('127.0.0.1:7711');
  await p.getByPlaceholder('用户名').fill('bill');
  await p.getByPlaceholder('密码', { exact: true }).fill('pass1234');
  await p.locator('button[type=submit]').click();
  await p.waitForTimeout(2500);
  await p.locator('.inbox article').first().waitFor({ timeout: 15000 });
  const wide = vp.width > 860;
  const nav = (label) => wide ? p.locator('.sidebar .side-item', { hasText: label }).first() : p.locator(`.topbar [aria-label="${label}"]`).first();
  const back = () => p.locator('.card-layer[data-state=in] [aria-label="返回"]').first().click();
  const pre = `${vp.tag}`;
  await capture(p, `${pre}-note`, () => p.locator('.inbox article', { hasText: '项目计划 Q4' }).first().click(), back);
  for (const [label, key] of [['任务', 'tasks'], ['日历', 'calendar'], ['回收站', 'trash'], ['传输', 'transfers'], ['设置', 'settings']]) {
    if (!wide && !(await nav(label).count())) {
      // 窄屏把次要入口收进「更多」
      continue;
    }
    await capture(p, `${pre}-${key}`, () => nav(label).click(), back);
  }
  if (wide && await p.locator('.sidebar .page-item').count()) {
    await capture(p, `${pre}-page`, () => p.locator('.sidebar .page-item').first().click(), back);
  }
  await capture(p, `${pre}-plusmenu`, () => p.locator('.composer [aria-label="新建"]').click(), () => p.mouse.click(5, vp.height / 2));
  await capture(p, `${pre}-ctxmenu`, () => p.locator('.inbox article', { hasText: '项目计划 Q4' }).first().click({ button: 'right' }), () => p.keyboard.press('Escape'));
  // 对话框：在回收站里点「清空」弹出确认卡片
  await nav('回收站').click();
  await p.waitForTimeout(800);
  await capture(p, `${pre}-dialog`, () => p.locator('.card-layer button', { hasText: '清空' }).click(), () => p.locator('.dialog button', { hasText: '取消' }).click());
  await p.close();
}
await b.close();
console.log('done');
