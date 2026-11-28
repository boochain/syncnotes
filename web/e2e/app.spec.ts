import { expect, test, type Browser, type Page } from '@playwright/test';

const server = () => process.env.E2E_SERVER!;
let seq = 0;
const uname = () => `e2e${Date.now() % 1_000_000}${seq++}`;

async function register(page: Page, user: string, pw = 'pass1234') {
  await page.goto('/');
  await page.getByRole('button', { name: '注册' }).click();
  await page.getByPlaceholder(/服务器地址/).fill(server());
  await page.getByPlaceholder('用户名').fill(user);
  await page.getByPlaceholder('密码', { exact: true }).fill(pw);
  await page.getByPlaceholder('再输入一次密码').fill(pw);
  await page.locator('button[type=submit]').click();
  // 恢复码只显示一次：点遮罩不能关掉，必须明确确认
  await expect(page.getByText('请保存恢复码')).toBeVisible();
  await page.mouse.click(5, 5);
  await expect(page.getByText('请保存恢复码')).toBeVisible();
  await page.getByRole('button', { name: '我已保存' }).click();
  await expect(page.getByPlaceholder('写一条消息，回车发送')).toBeVisible();
}

async function login(page: Page, user: string, pw = 'pass1234') {
  await page.goto('/');
  await page.getByPlaceholder(/服务器地址/).fill(server());
  await page.getByPlaceholder('用户名').fill(user);
  await page.getByPlaceholder('密码', { exact: true }).fill(pw);
  await page.locator('button[type=submit]').click();
  await expect(page.getByPlaceholder('写一条消息，回车发送')).toBeVisible();
}

async function second(browser: Browser, user: string) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const p = await ctx.newPage();
  await login(p, user);
  return p;
}

function collectErrors(page: Page): string[] {
  const errs: string[] = [];
  page.on('pageerror', (e) => errs.push(e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') errs.push(m.text());
  });
  return errs;
}

test('register, send a message, it survives a reload', async ({ page }) => {
  const errs = collectErrors(page);
  const u = uname();
  await register(page, u);
  const compose = page.getByPlaceholder('写一条消息，回车发送');
  await compose.fill('你好 SyncNotes');
  await compose.press('Enter');
  await expect(page.getByText('你好 SyncNotes').first()).toBeVisible();
  await page.reload();
  await expect(page.getByText('你好 SyncNotes').first()).toBeVisible({ timeout: 10_000 });
  expect(errs).toEqual([]);
});

test('two clients sync in real time (create + delete)', async ({ page, browser }) => {
  const u = uname();
  await register(page, u);
  const b = await second(browser, u);
  const compose = page.getByPlaceholder('写一条消息，回车发送');
  await compose.fill('实时同步测试');
  await compose.press('Enter');
  await expect(b.getByText('实时同步测试').first()).toBeVisible({ timeout: 10_000 });
  // B 上移到回收站 → A 上消失
  await b.getByText('实时同步测试').first().click({ button: 'right' });
  await b.getByRole('button', { name: '移到回收站' }).click();
  await expect(page.getByText('实时同步测试')).toHaveCount(0, { timeout: 10_000 });
  // 回收站里能看到并还原
  await page.getByRole('button', { name: '回收站' }).click();
  await expect(page.getByText('实时同步测试').first()).toBeVisible();
  await b.context().close();
});

test('tasks and calendar pages open and show empty states', async ({ page }) => {
  const errs = collectErrors(page);
  const u = uname();
  await register(page, u);
  await page.getByRole('button', { name: '任务' }).click();
  await expect(page.getByRole('region', { name: '任务' })).toBeVisible();
  await page.getByRole('button', { name: '返回' }).first().click();
  await page.getByRole('button', { name: '日历' }).click();
  await expect(page.getByRole('region', { name: '日历' })).toBeVisible();
  expect(errs).toEqual([]);
});

test('wrong password is rejected with a readable message', async ({ page }) => {
  const u = uname();
  await register(page, u);
  const p2 = await page.context().browser()!.newContext().then((c) => c.newPage());
  await p2.goto('/');
  await p2.getByPlaceholder(/服务器地址/).fill(server());
  await p2.getByPlaceholder('用户名').fill(u);
  await p2.getByPlaceholder('密码', { exact: true }).fill('wrong-pass');
  await p2.locator('button[type=submit]').click();
  await expect(p2.getByText('用户名或密码错误')).toBeVisible();
  await p2.context().close();
});

// v0.8.2：弹出页是不透明圆角卡片，打开时下层界面模糊并淡出（只露背景），关闭时先播退出动画再卸载。
test('pop-ups are opaque cards and hide the page below', async ({ page }) => {
  const errs = collectErrors(page);
  await register(page, uname());
  await page.getByRole('button', { name: '回收站' }).first().click();
  const card = page.locator('.card-layer .page');
  await expect(card).toBeVisible();
  const look = await card.evaluate((el) => {
    const cs = getComputedStyle(el);
    return { bg: cs.backgroundColor, radius: parseFloat(cs.borderTopLeftRadius), rect: el.getBoundingClientRect().toJSON() };
  });
  expect(look.bg).toMatch(/^rgb\(/); // 不透明（rgba 才带透明度）
  expect(look.radius).toBeGreaterThanOrEqual(16);
  expect(look.rect.left).toBeGreaterThanOrEqual(8);
  expect(look.rect.top).toBeGreaterThanOrEqual(8);
  // 下层（侧栏、收件箱）完全淡出并模糊
  await expect.poll(() => page.locator('.inbox').evaluate((el) => getComputedStyle(el).opacity)).toBe('0');
  expect(await page.locator('.inbox').evaluate((el) => getComputedStyle(el).filter)).toContain('blur');
  // 对话框也是卡片，下层（包括回收站卡片）整体隐去
  await page.locator('.card-layer button', { hasText: '清空' }).click();
  await expect(page.getByRole('dialog', { name: /清空回收站/ })).toBeVisible();
  await expect.poll(() => page.locator('.shell').evaluate((el) => getComputedStyle(el).opacity)).toBe('0');
  await page.locator('.dialog button', { hasText: '取消' }).click();
  await expect(page.locator('.popup-root')).toHaveCount(0);
  // 返回：卡片先退出，再卸载，下层恢复
  await page.getByRole('button', { name: '返回' }).first().click();
  await expect(page.locator('.card-layer')).toHaveAttribute('data-state', 'out');
  await expect(page.locator('.card-layer')).toHaveCount(0);
  await expect.poll(() => page.locator('.inbox').evaluate((el) => getComputedStyle(el).opacity)).toBe('1');
  expect(errs).toEqual([]);
});
