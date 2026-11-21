// V2 batch 1「玩法深化」screenshots (mock mode): every new page / tab / drawer
// into ./screenshots/v2. Fails if the browser console reports errors or warnings.
//
//   npm run dev:mock
//   npm run screenshots:v2            # 地址取自 config.yaml 的 dev_server；端口变了可加 BASE_URL=http://localhost:5174
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');

const { baseUrl: BASE, adminPrefix } = require('./devConfig.cjs');
const OUT = path.join(__dirname, '..', 'screenshots', process.env.SHOT_DIR || 'v2');
const PASSWORD = process.env.ADMIN_PASSWORD || 'loopland';

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
    page.on('response', (r) => {
      if (r.url().includes(`${adminPrefix}/`) && r.status() >= 400 && !process.env.ALLOW_HTTP_ERRORS) problems.push(`[${username}] HTTP ${r.status()} ${r.request().method()} ${r.url()}`);
    });
    await page.goto(`${BASE}/login`);
    await page.fill('#username', username);
    await page.fill('#password', username === 'admin' ? PASSWORD : process.env.STAFF_PASSWORD || 'loopland');
    await page.click('button[type=submit]');
    await page.waitForSelector('h1.page-title');
    return { ctx, page };
  }

  async function shot(page, name, opts = {}) {
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(opts.wait ?? 900);
    await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: opts.fullPage ?? true });
    console.log('saved', name);
  }

  const clickSvgTitle = (page, re) =>
    page.evaluate((src) => {
      const r = new RegExp(src);
      const t = [...document.querySelectorAll('svg title')].find((x) => r.test(x.textContent || ''));
      t?.parentElement?.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      return !!t;
    }, re);

  const { ctx, page } = await session('admin');

  // 总览
  await page.goto(`${BASE}/`);
  await page.waitForSelector('text=待处理事项');
  if (!process.env.NO_BOSS_CARD) await page.waitForSelector('text=进行中的怪兽');
  await shot(page, '01_总览_进行中的怪兽');

  // 地图与领地
  await page.goto(`${BASE}/territories`);
  await page.waitForSelector('text=召唤怪兽');
  await shot(page, '02_地图_怪兽宝箱打卡点');
  if (await clickSvgTitle(page, 'Lv\\.')) {
    await page.waitForSelector('text=伤害排名与掉落');
    await shot(page, '02b_地图_选中怪兽');
  } else problems.push('no boss on the map');
  if (await clickSvgTitle(page, '^宝箱 #')) {
    await page.waitForSelector('.panel-title:has-text("宝箱")');
    await shot(page, '02c_地图_选中宝箱', { fullPage: false });
  }
  await page.click('button:has-text("召唤怪兽")');
  await page.waitForSelector('.ant-modal-title:has-text("召唤怪兽")');
  await shot(page, '02d_召唤怪兽', { fullPage: false });
  await page.click('.ant-modal button:has-text("地图选点")');
  await page.waitForSelector('.pick-banner');
  await shot(page, '02e_召唤怪兽_地图选点', { fullPage: false });
  const box = await page.locator('.map-wrap > svg[role=img]').first().boundingBox();
  await page.mouse.click(box.x + box.width * 0.62, box.y + box.height * 0.45);
  await page.waitForSelector('.ant-modal-title:has-text("召唤怪兽")');
  await page.fill('#location_name', '世纪广场一带');
  await shot(page, '02f_召唤怪兽_已选点', { fullPage: false });
  if (!process.env.NO_WRITES) {
    await page.click('.ant-modal-footer button:has-text("召唤")');
    await page.waitForSelector('text=伤害排名与掉落');
    await shot(page, '02g_召唤后');
  } else {
    await page.click('.ant-modal-footer button:has-text("取消")');
  }
  await page.click('button:has-text("投放宝箱")');
  await page.waitForSelector('.ant-modal-title:has-text("投放宝箱")');
  await shot(page, '02h_投放宝箱', { fullPage: false });
  await page.click('.ant-modal-wrap:not([style*="display: none"]) .ant-modal-footer button:has-text("取消")');
  await page.click('button:has-text("批量撒宝箱")');
  await page.waitForSelector('.ant-modal-title:has-text("批量撒宝箱")');
  await shot(page, '02i_批量撒宝箱', { fullPage: false });
  if (!process.env.NO_WRITES) {
    await page.click('.ant-modal-footer button:has-text("撒宝箱")');
    await page.waitForSelector('.ant-message-success');
    await shot(page, '02j_撒宝箱后');
  } else await page.click('.ant-modal-wrap:not([style*="display: none"]) .ant-modal-footer button:has-text("取消")');

  // 玩法运营
  await page.goto(`${BASE}/operations`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '03_玩法运营_城市怪兽');
  await page.locator('.ant-table-row').first().locator('button:has-text("详情")').click();
  await page.waitForSelector('text=掉落表（App 公示）');
  await shot(page, '03b_怪兽详情_进行中', { fullPage: false });
  await page.locator('.ant-drawer-extra button:has-text("提前结束")').click();
  await page.waitForSelector('.ant-modal-confirm-title');
  await shot(page, '03c_提前结束确认', { fullPage: false });
  await page.click('.ant-modal-confirm-btns button:has-text("取消")');
  await page.goto(`${BASE}/operations?status=defeated`);
  await page.waitForSelector('.ant-table');
  await page.waitForLoadState('networkidle');
  const defeatedRow = page.locator('.ant-table-row').first();
  if (await defeatedRow.locator('button:has-text("详情")').count()) {
    await defeatedRow.locator('button:has-text("详情")').click();
    await page.waitForSelector('text=掉落表（App 公示）');
    await shot(page, '03d_怪兽详情_已击败_奖励', { fullPage: false });
  }

  await page.goto(`${BASE}/operations?tab=chests`);
  await page.waitForSelector('.ant-table');
  await shot(page, '04_玩法运营_宝箱');

  await page.goto(`${BASE}/operations?tab=seasons`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '05_玩法运营_赛季');
  await page.click('button:has-text("新建赛季")');
  await page.waitForSelector('.ant-modal-title:has-text("新建赛季")');
  await page.fill('#name', 'S5 测试赛');
  await shot(page, '05b_新建赛季', { fullPage: false });
  await page.click('.ant-modal-wrap:not([style*="display: none"]) .ant-modal-footer button:has-text("取消")');
  const settleBtn = page.locator('.ant-table-row button:has-text("手动结算"):not([disabled])').first();
  if (await settleBtn.count()) {
    await settleBtn.click();
    await page.waitForSelector('.ant-modal-confirm-title:has-text("结算")');
    await shot(page, '05c_手动结算_第一步', { fullPage: false });
    await page.click('.ant-modal-confirm-btns button:has-text("下一步")');
    await page.waitForSelector('.ant-modal-confirm-title:has-text("再次确认结算")');
    await shot(page, '05d_手动结算_第二步', { fullPage: false });
    await page.click('.ant-modal-confirm-btns button:has-text("取消")');
  }
  const editBtn = page.locator('.ant-table-row button:has-text("编辑"):not([disabled])').first();
  if (await editBtn.count()) {
    await editBtn.click();
    await page.waitForSelector('.ant-modal-title:has-text("编辑")');
    await shot(page, '05e_编辑赛季', { fullPage: false });
    await page.click('.ant-modal-wrap:not([style*="display: none"]) .ant-modal-footer button:has-text("取消")');
  }

  await page.goto(`${BASE}/operations?tab=campaigns`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '06_玩法运营_限时活动');
  await page.click('button:has-text("新建活动")');
  await page.waitForSelector('.ant-modal-title:has-text("新建限时活动")');
  await shot(page, '06b_新建活动_夜跑', { fullPage: false });
  await page.locator('.ant-modal .ant-select').first().click();
  await page.click('.ant-select-item-option:has-text("配速挑战")');
  await page.fill('#title', '破 5 挑战');
  await page.fill('#pace', '5:00');
  await shot(page, '06c_新建活动_配速', { fullPage: false });
  if (!process.env.NO_WRITES) {
    await page.click('.ant-modal-footer button:has-text("保存")');
    await page.waitForSelector('text=活动已创建');
    await shot(page, '06d_活动已创建');
  } else await page.click('.ant-modal-wrap:not([style*="display: none"]) .ant-modal-footer button:has-text("取消")');

  await page.goto(`${BASE}/operations?tab=routes`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, '07_玩法运营_城市定向');
  await page.locator('.ant-table-row').first().locator('button:has-text("编辑")').click();
  await page.waitForSelector('text=打卡点');
  await page.waitForTimeout(600);
  await shot(page, '07b_定向路线编辑', { fullPage: false });
  await page.click('.ant-drawer-extra button:has-text("取消")');
  await page.click('button:has-text("新建路线")');
  await page.waitForSelector('.ant-drawer-title:has-text("新建定向路线")');
  await page.click('.ant-drawer button:has-text("添加打卡点")');
  await page.click('.ant-drawer-extra button:has-text("保存")');
  await page.waitForTimeout(400);
  await shot(page, '07c_新建路线_校验', { fullPage: false });
  await page.click('.ant-drawer-extra button:has-text("取消")');

  await page.goto(`${BASE}/operations?tab=league`);
  await page.waitForSelector('text=城区联赛');
  await shot(page, '08_玩法运营_城区联赛');

  // 玩法配置 new tabs
  for (const [tab, name] of [
    ['buildings', '建筑_图纸越级'],
    ['boss', '怪兽'],
    ['chest', '宝箱'],
    ['defense', '守地'],
    ['tiers', '赛季段位'],
    ['tasks', '赛季任务'],
    ['medals', '奖牌'],
    ['companion', '伙伴养成'],
    ['relay', '跑团接力'],
  ]) {
    await page.goto(`${BASE}/gameplay${tab === 'buildings' ? '' : `?tab=${tab}`}`);
    await page.waitForSelector('text=未发布改动');
    if (tab === 'buildings') {
      await page.locator('.ant-table-row').first().locator('.ant-checkbox-input').click();
    }
    await shot(page, `09_玩法配置_${name}`);
  }
  // validation: tiers not increasing + diff list
  await page.goto(`${BASE}/gameplay?tab=tiers`);
  await page.waitForSelector('text=赛季内新圈面积');
  await page.goto(`${BASE}/gameplay?tab=tiers`);
  await page.waitForSelector('text=赛季内新圈面积');
  await page.locator('.ant-table-row').nth(2).locator('input.ant-input-number-input').fill('0.3');
  await page.locator('.ant-table-row').nth(2).locator('input.ant-input-number-input').blur();
  await page.locator('.ant-table-row').nth(0).locator('input.ant-input').fill('黑铁');
  await shot(page, '09b_玩法配置_段位校验与改动');

  // 系统配置 · 第三方服务 (admin only)
  await page.click('nav.side a[aria-label="系统配置"]');
  await page.waitForSelector('.prov-card[data-code="amap"]');
  await page.mouse.move(1200, 5);
  await shot(page, '13_系统配置_第三方服务');
  await page.locator('.prov-card[data-code="ai"] button:has-text("编辑配置")').click();
  await page.waitForSelector('.ant-drawer-title:has-text("AI 大模型")');
  await shot(page, '13b_系统配置_编辑AI大模型', { fullPage: false });
  await page.click('.ant-drawer button:has-text("取消")');
  await page.locator('.prov-card[data-code="realname"] button:has-text("测试连接")').click();
  await page.waitForSelector('.ant-modal-title:has-text("实名核验")');
  await shot(page, '13c_系统配置_测试实名核验', { fullPage: false });
  await page.click('.ant-modal-footer button:has-text("取消")');
  await ctx.close();

  // ops: can use 玩法运营; cannot publish
  const ops = await session('xiaolin');
  await ops.page.goto(`${BASE}/operations`);
  await ops.page.waitForSelector('.ant-table-row');
  await shot(ops.page, '10_运营视角_玩法运营', { fullPage: false });
  if (await ops.page.locator('nav.side a[aria-label="系统配置"]').count()) problems.push('[xiaolin] 系统配置 menu visible to ops');
  await ops.ctx.close();

  // reviewer: no 玩法运营
  if (!process.env.SKIP_REVIEWER) {
    const rv = await session('amei');
    await rv.page.goto(`${BASE}/operations`);
    await rv.page.waitForSelector('text=没有权限');
    await shot(rv.page, '10b_审核员视角_玩法运营403', { fullPage: false });
    const menu = await rv.page.locator('nav.side a').count();
    if (menu !== 3) problems.push(`[amei] expected 3 menu links, got ${menu}`);
    await rv.ctx.close();
  }

  // narrow
  const m = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  const mp = await m.newPage();
  mp.on('pageerror', (e) => problems.push(`[mobile] pageerror: ${e.message}`));
  await mp.goto(`${BASE}/login`);
  await mp.fill('#username', 'admin');
  await mp.fill('#password', PASSWORD);
  await mp.click('button[type=submit]');
  await mp.waitForSelector('h1.page-title');
  await mp.goto(`${BASE}/operations`);
  await mp.waitForSelector('.ant-table');
  await shot(mp, '11_窄屏_玩法运营');
  await m.close();

  await browser.close();
  if (problems.length) {
    console.error('\nProblems:\n' + [...new Set(problems)].join('\n'));
    process.exit(1);
  }
  console.log('\nNo console errors or warnings.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
