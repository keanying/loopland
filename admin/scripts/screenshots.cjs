// Loads every page of the admin console (run it against `pnpm run dev:mock`)
// and saves full-page PNGs into ./screenshots. Fails if the browser console
// reports errors.
//
//   pnpm run dev:mock            # in one terminal
//   pnpm run screenshots            # 地址取自 config.yaml 的 dev_server；端口变了可加 BASE_URL=http://localhost:5174
// 真实后端的管理员账号（默认 looproot）；假数据模式下 admin 也能登录
const ADMIN_USER = process.env.ADMIN_USERNAME || 'admin';
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');

const { baseUrl: BASE } = require('./devConfig.cjs');
const OUT = path.join(__dirname, '..', 'screenshots');

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  const problems = [];

  async function session(username) {
    const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, locale: 'zh-CN' });
    const page = await ctx.newPage();
    page.on('console', (m) => {
      if (m.type() === 'error' || m.type() === 'warning') problems.push(`[${username}] console.${m.type()}: ${m.text()}`);
    });
    page.on('pageerror', (e) => problems.push(`[${username}] pageerror: ${e.message}`));
    await page.goto(`${BASE}/login`);
    await page.waitForSelector('text=运营后台');
    return { ctx, page };
  }

  async function shot(page, name, opts = {}) {
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(opts.wait ?? 1200);
    await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: opts.fullPage ?? true });
    console.log('saved', name);
  }

  async function login(page, username) {
    await page.fill('#username', username === 'admin' ? ADMIN_USER : username);
    await page.fill('#password', 'loopland');
    await page.click('button[type=submit]');
    await page.waitForSelector('h1.page-title');
  }

  // ---------------- admin ----------------
  const { ctx, page } = await session('admin');
  await shot(page, '00_登录', { fullPage: false });
  await login(page, 'admin');

  await page.goto(`${BASE}/`);
  await page.waitForSelector('text=待处理事项');
  await shot(page, '01_总览');
  await page.click('button:has-text("看表格")');
  await shot(page, '01b_总览_表格');

  await page.goto(`${BASE}/users`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '02_用户管理');
  await page.goto(`${BASE}/users?id=10293`);
  await page.waitForSelector('text=查看完整号码');
  await page.click('button:has-text("查看完整号码")');
  await page.waitForTimeout(500);
  await shot(page, '02b_用户详情', { fullPage: false });

  await page.goto(`${BASE}/plans`);
  await page.waitForSelector('text=圈地会员');
  await page.locator('.plan-card').first().locator('input').nth(1).fill('6');
  await shot(page, '03_会员套餐');
  await page.goto(`${BASE}/plans?tab=entitlements`);
  await page.waitForSelector('text=权益矩阵');
  await shot(page, '03b_权益矩阵');
  await page.goto(`${BASE}/plans?tab=orders`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '03c_订单');
  await page.locator('button:has-text("退款")').first().click();
  await page.waitForSelector('text=第 1 步');
  await shot(page, '03d_退款第一步', { fullPage: false });
  await page.click('.ant-modal-footer button:has-text("下一步")');
  await page.waitForSelector('.ant-modal-confirm-title:has-text("再次确认退款")');
  await shot(page, '03e_退款第二步', { fullPage: false });
  await page.click('.ant-modal-confirm-btns button:has-text("取消")');

  await page.goto(`${BASE}/territories?id=102`);
  await page.waitForSelector('text=领地列表');
  await page.waitForSelector('text=守卫值');
  await shot(page, '04_地图与领地');

  await page.goto(`${BASE}/risk`);
  await page.waitForSelector('text=速度曲线');
  await shot(page, '06_风控防作弊');
  await page.goto(`${BASE}/risk?alert=10`);
  await page.waitForSelector('text=段瞬移');
  await shot(page, '06b_风控_轨迹瞬移');

  await page.goto(`${BASE}/gameplay`);
  await page.waitForSelector('text=未发布改动');
  await shot(page, '08_玩法配置_建筑');
  const cost = page.locator('.ant-table-row').first().locator('input').first();
  await cost.fill('90');
  await cost.blur();
  await shot(page, '08b_玩法配置_改动');
  await page.click('.ant-segmented-item:has-text("怪兽掉落")');
  await page.waitForSelector('text=怪兽掉落表');
  const pct = page.locator('.tile').first().locator('input').first();
  await pct.fill('40');
  await pct.blur();
  await shot(page, '08c_玩法配置_掉落不足100');
  await page.click('.ant-segmented-item:has-text("角色")');
  await shot(page, '08d_玩法配置_角色');
  await page.click('.ant-segmented-item:has-text("能量换算")');
  await shot(page, '08e_玩法配置_能量换算');

  await page.goto(`${BASE}/audit`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '09_审计日志');

  await page.goto(`${BASE}/admins`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '10_后台账号');
  await ctx.close();

  // ---------------- ops: admin-only actions hidden/disabled ----------------
  const ops = await session('xiaolin');
  await login(ops.page, 'xiaolin');
  await ops.page.goto(`${BASE}/gameplay`);
  await ops.page.waitForSelector('text=未发布改动');
  await shot(ops.page, '11_运营视角_玩法配置');
  await ops.page.goto(`${BASE}/admins`);
  await ops.page.waitForSelector('text=没有权限');
  await shot(ops.page, '11b_运营视角_后台账号403', { fullPage: false });
  await ops.ctx.close();

  // ---------------- reviewer: only users + risk; no 403 toasts ----------------
  const rv = await session('amei');
  await login(rv.page, 'amei');
  for (const url of ['/', '/users', '/risk']) {
    await rv.page.goto(`${BASE}${url}`);
    await rv.page.waitForLoadState('networkidle');
    await rv.page.waitForTimeout(500);
    if (await rv.page.locator('.ant-message-error').count()) problems.push(`[amei] error toast on ${url}`);
  }
  await shot(rv.page, '11c_审核员视角_风控', { fullPage: false });
  const menu = await rv.page.locator('nav.side a').count();
  if (menu !== 4) problems.push(`[amei] expected 4 menu links (总览/用户/内容审核/风控), got ${menu}`);
  await rv.ctx.close();

  // ---------------- narrow viewport ----------------
  const m = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  const mp = await m.newPage();
  mp.on('pageerror', (e) => problems.push(`[mobile] pageerror: ${e.message}`));
  await mp.goto(`${BASE}/login`);
  await mp.fill('#username', ADMIN_USER);
  await mp.fill('#password', 'loopland');
  await mp.click('button[type=submit]');
  await mp.waitForSelector('text=待处理事项');
  await shot(mp, '12_窄屏_总览');
  await m.close();

  await browser.close();
  if (problems.length) {
    console.error('\nConsole problems:\n' + [...new Set(problems)].join('\n'));
    process.exit(1);
  }
  console.log('\nNo console errors or warnings.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
