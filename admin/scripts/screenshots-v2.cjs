// V2 screenshots (mock mode): batch 1「玩法深化」and batch 2「社区」(14_ onwards) — every new
// page / tab / drawer into ./screenshots/v2. Fails if the browser console reports errors or warnings.
//
//   pnpm run dev:mock
//   pnpm run screenshots:v2            # 地址取自 config.yaml 的 dev_server；端口变了可加 BASE_URL=http://localhost:5174
//   ONLY=community pnpm run screenshots:v2   # 只跑第二批「社区」(内容审核 / 举报 / 动态 / 敏感词 / 组局 / 赛事 / 总览 / 角色)
//   ONLY=ai pnpm run screenshots:v2          # 只跑第三批「AI」(23_ 起：AI 审核 / 双阈值 / AI 用量 / AI 对话 / AI 大模型 / 跟练配置 / 角色)
//   ONLY=perks pnpm run screenshots:v2       # 只跑第四批的投放 / 联名活动 / 能量商城 / 补给站图层（scripts/screenshots-v2-perks.cjs）
//   ONLY=merchant pnpm run screenshots:v2    # 只跑第四批的商户 / 场馆 / 订场 / 核销结算 / 核销台（含窄屏商户对接 + 假摄像头扫码）/ 总览待办（scripts/screenshots-v2-merchant.cjs）
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');

const { baseUrl: BASE, adminPrefix } = require('./devConfig.cjs');
const OUT = path.join(__dirname, '..', 'screenshots', process.env.SHOT_DIR || 'v2');
const PASSWORD = process.env.ADMIN_PASSWORD || 'loopland';
const ONLY_COMMUNITY = process.env.ONLY === 'community';
const ONLY_AI = process.env.ONLY === 'ai';
const ONLY_PERKS = process.env.ONLY === 'perks';
const perksShots = require('./screenshots-v2-perks.cjs');
const ONLY_MERCHANT = process.env.ONLY === 'merchant';
const merchantShots = require('./screenshots-v2-merchant.cjs');
const WRITES = !process.env.NO_WRITES;

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

  if (ONLY_MERCHANT) {
    await merchantShots({ browser, session, shot, BASE, problems, writes: WRITES });
    return finish();
  }

  if (ONLY_PERKS) {
    await perksShots({ browser, session, shot, BASE, problems, writes: WRITES });
    return finish();
  }

  const { ctx, page } = await session('admin');

  if (!ONLY_COMMUNITY && !ONLY_AI) {
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
  }

  if (!ONLY_AI) await community(page);
  if (!ONLY_COMMUNITY) await aiBatch(page);
  await ctx.close();

  if (!ONLY_COMMUNITY && !ONLY_AI) {
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
    if (menu !== 4) problems.push(`[amei] expected 4 menu links (总览/用户/内容审核/风控), got ${menu}`);
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
  }

  if (!ONLY_AI) await communityRoles();
  if (!ONLY_COMMUNITY) await aiRoles();

  // ---------------------------------------------------------------- V2 第三批「AI」
  async function aiBatch(page) {
    const visibleModal = '.ant-modal-wrap:not([style*="display: none"])';
    const activeId = () => page.locator('.rv-item.active').getAttribute('data-id');

    // 23 内容审核: AI 判定 next to the rule reasons, author violations, new decision buttons
    await page.goto(`${BASE}/review`);
    await page.waitForSelector('.rv-item.active');
    await page.waitForSelector('.ai-box');
    await page.mouse.move(1200, 5);
    await shot(page, '23_AI审核_判定详情');

    // B = 驳回并禁言 (editable days)
    const before = await activeId();
    await page.keyboard.press('b');
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("驳回并禁言")`);
    await page.click(`${visibleModal} .reason-presets .ant-tag-checkable:has-text("涉嫌诈骗")`);
    await page.fill(`${visibleModal} input[aria-label="禁言天数"]`, '14');
    await page.waitForSelector(`${visibleModal} button:has-text("驳回并禁言 14 天")`);
    await shot(page, '23b_AI审核_驳回并禁言', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("驳回并禁言 14 天")`);
      await page.waitForSelector('.ant-message-success:has-text("已驳回并禁言 14 天")');
      await page.waitForTimeout(600);
      if ((await activeId()) === before) problems.push('[ai] did not advance to the next task after 驳回并禁言');
      await shot(page, '23c_AI审核_处理后跳到下一条', { fullPage: false });
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);

    // filter by AI suggestion: 建议隐藏起终点 → H
    await page.goto(`${BASE}/review?ai=hide_endpoints`);
    await page.waitForSelector('.rv-item.active');
    await page.waitForSelector('.decide-btn.suggested[data-action="approve_hide_endpoints"]');
    await page.mouse.move(1200, 5);
    await shot(page, '23d_AI审核_建议隐藏起终点');
    if (WRITES) {
      await page.keyboard.press('h');
      await page.waitForSelector('.ant-message-success:has-text("已隐藏起终点后通过")');
    }

    // 建议打码 → M
    await page.goto(`${BASE}/review?ai=mask&sort=confidence`);
    await page.waitForSelector('.rv-item.active');
    await page.locator('.decide-btn[data-action="approve_masked"] button').hover();
    await page.waitForSelector('.ant-tooltip:has-text("替换为 *")');
    await shot(page, '23e_AI审核_建议打码_按置信度排序', { fullPage: false });
    if (WRITES) {
      await page.mouse.move(1200, 5);
      await page.keyboard.press('m');
      await page.waitForSelector('.ant-message-success:has-text("已打码后通过")');
      // in-app navigation: a page load would reset the in-memory mock
      await page.click('.ant-segmented-item:has-text("已通过")');
      await page.waitForSelector('.rv-item .rv-text:has-text("***")');
      await shot(page, '23f_AI审核_打码后的记录');
    }
    // no AI verdict (timed out → rules only)
    await page.goto(`${BASE}/review?ai=none`);
    await page.waitForSelector('.rv-item.active');
    await page.waitForSelector('text=没有 AI 判定');
    await shot(page, '23g_AI审核_没有AI判定', { fullPage: false });

    // 24 审核设置: two thresholds + live estimate
    await page.goto(`${BASE}/review?tab=settings`);
    await page.waitForSelector('[data-testid="est-manual"]');
    const est0 = await page.locator('[data-testid="est-manual"]').textContent();
    await page.fill('input[aria-label="自动放行线"]', '10');
    await page.locator('input[aria-label="自动放行线"]').blur();
    await page.fill('input[aria-label="自动拦截线"]', '80');
    await page.locator('input[aria-label="自动拦截线"]').blur();
    await page.waitForFunction((v) => document.querySelector('[data-testid="est-manual"]')?.textContent !== v, est0);
    await page.waitForTimeout(500);
    await shot(page, '24_审核设置_双阈值');
    await page.click('button[aria-label="AI 审核"]');
    await page.waitForSelector('text=AI 审核已关闭');
    await page.locator('.panel:has-text("审核阈值")').first().scrollIntoViewIfNeeded();
    await shot(page, '24b_审核设置_关闭AI', { fullPage: false });
    if (WRITES) {
      await page.click('button[aria-label="AI 审核"]');
      await page.click('button:has-text("保存设置")');
      await page.waitForSelector('.ant-message-success:has-text("已保存")');
    }

    // 25 AI 用量
    await page.click('nav.side a[aria-label="AI 用量"]');
    await page.waitForSelector('text=各功能用量');
    await page.waitForSelector('.ant-table-row');
    await page.mouse.move(1200, 5);
    await shot(page, '25_AI用量');
    await page.click('.ant-segmented-item:has-text("近 30 天")');
    await page.click('.ant-segmented-item:has-text("失败")');
    await page.waitForTimeout(600);
    await shot(page, '25b_AI用量_失败_30天', { fullPage: false });
    await page.click('.ant-segmented-item:has-text("Token")');
    await page.waitForTimeout(600);
    await shot(page, '25c_AI用量_Token', { fullPage: false });
    await page.goto(`${BASE}/ai-usage?feature=moderation&status=failed`);
    await page.waitForSelector('.ant-table-row:has-text("失败")');
    await page.locator('.panel:has-text("调用记录")').last().scrollIntoViewIfNeeded();
    await shot(page, '25d_AI用量_失败的审核调用', { fullPage: false });

    // 26 查看用户 AI 对话 (admin only, audited)
    await page.goto(`${BASE}/users?id=10293`);
    await page.click('.ant-drawer button:has-text("查看 AI 对话")');
    await page.waitForSelector('.ant-modal-confirm-title:has-text("AI 对话")');
    await shot(page, '26_用户_查看AI对话确认', { fullPage: false });
    await page.click('.ant-modal-confirm-btns button:has-text("确认查看")');
    await page.waitForSelector('.chat-msg');
    await shot(page, '26b_用户_AI对话', { fullPage: false });
    await page.keyboard.press('Escape');
    await page.keyboard.press('Escape');
    await page.click('nav.side a[aria-label="审计日志"]');
    await page.waitForSelector('text=查看用户 AI 对话');
    await shot(page, '26c_审计_查看AI对话', { fullPage: false });

    // 27 系统配置 → AI 大模型: vision model and prices come from the field definitions
    await page.goto(`${BASE}/settings/providers?group=AI`);
    await page.waitForSelector('.prov-card[data-code="ai"]');
    await page.locator('.prov-card[data-code="ai"] button:has-text("编辑配置")').click();
    await page.waitForSelector('.ant-drawer-title:has-text("AI 大模型")');
    await page.waitForSelector('.ant-drawer label:has-text("视觉模型")');
    await page.locator('.ant-drawer label:has-text("输出单价")').scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
    await shot(page, '27_系统配置_AI大模型_视觉与单价', { fullPage: false });
    await page.click('.ant-drawer button:has-text("取消")');

    // 28 玩法配置: AI 跟练 + AI
    await page.goto(`${BASE}/gameplay?tab=workouts`);
    await page.waitForSelector('.wk-card');
    const step = page.locator('.wk-card[data-workout="rope_basic"] .wk-step').first();
    await step.locator('.ant-input-number-input').first().fill('120');
    await step.locator('.ant-input-number-input').first().blur();
    await page.locator('.wk-card[data-workout="hiit_burn"] button:has-text("添加动作")').click();
    await page.locator('.wk-card[data-workout="hiit_burn"] .wk-step').last().locator('input[aria-label="动作名称"]').fill('波比跳');
    await page.locator('.wk-card[data-workout="hiit_burn"] .wk-step').last().locator('input[aria-label="动作 key"]').fill('burpee');
    await page.locator('.wk-card[data-workout="hiit_burn"] .wk-step').last().locator('input[aria-label="语音提示"]').fill('累了可以去掉跳跃');
    await page.locator('.wk-card[data-workout="pilates_core"] .wk-step').nth(1).locator('input[aria-label="动作名称"]').fill('');
    await page.waitForTimeout(300);
    await shot(page, '28_玩法配置_AI跟练');
    await page.goto(`${BASE}/gameplay?tab=ai`);
    await page.waitForSelector('text=助手带上的历史轮数');
    await shot(page, '28b_玩法配置_AI');
  }

  async function aiRoles() {
    // ops: AI 用量 yes, 系统配置 / 查看 AI 对话 no
    const ops = await session('xiaolin');
    if (!(await ops.page.locator('nav.side a[aria-label="AI 用量"]').count())) problems.push('[xiaolin] AI 用量 menu missing for ops');
    await ops.page.goto(`${BASE}/ai-usage`);
    await ops.page.waitForSelector('text=各功能用量');
    await ops.page.waitForSelector('.ant-table-row');
    await shot(ops.page, '29_运营视角_AI用量', { fullPage: false });
    await ops.page.goto(`${BASE}/users?id=10293`);
    await ops.page.waitForSelector('.ant-drawer button:has-text("赠送 7 天会员")');
    if (await ops.page.locator('.ant-drawer button:has-text("查看 AI 对话")').count()) problems.push('[xiaolin] 查看 AI 对话 visible to ops');
    await ops.ctx.close();

    // reviewer: no AI 用量
    const rv = await session('amei');
    if (await rv.page.locator('nav.side a[aria-label="AI 用量"]').count()) problems.push('[amei] AI 用量 menu visible to reviewer');
    await rv.page.goto(`${BASE}/ai-usage`);
    await rv.page.waitForSelector('text=没有权限');
    await shot(rv.page, '29b_审核员视角_AI用量403', { fullPage: false });
    await rv.page.goto(`${BASE}/review`);
    await rv.page.waitForSelector('.ai-box');
    await rv.ctx.close();

    // narrow
    const m = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    const mp = await m.newPage();
    mp.on('pageerror', (e) => problems.push(`[mobile] pageerror: ${e.message}`));
    await mp.goto(`${BASE}/login`);
    await mp.fill('#username', 'admin');
    await mp.fill('#password', PASSWORD);
    await mp.click('button[type=submit]');
    await mp.waitForSelector('h1.page-title');
    await mp.goto(`${BASE}/ai-usage`);
    await mp.waitForSelector('.ant-table-row');
    await shot(mp, '30_窄屏_AI用量');
    await m.close();
  }

  // ---------------------------------------------------------------- V2 第二批「社区」
  async function community(page) {
    const visibleModal = '.ant-modal-wrap:not([style*="display: none"])';
    // 14 内容审核 · 审核队列
    await page.goto(`${BASE}/review`);
    await page.waitForSelector('.rv-item');
    await page.mouse.move(1200, 5);
    await shot(page, '14_社区_内容审核');
    await page.locator('.rv-item:has(.thumbs) .rv-meta').first().click(); // highest-risk task may have no images
    await page.locator('.panel.grey .thumbs .ant-image').first().click();
    await page.waitForSelector('.ant-image-preview-img');
    await shot(page, '14b_内容审核_点击放大', { fullPage: false });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);
    if (WRITES) {
      // keyboard: J moves down, A approves the highlighted one
      await page.keyboard.press('j');
      await page.waitForTimeout(150);
      await page.keyboard.press('a');
      await page.waitForSelector('.ant-message-success:has-text("已通过")');
    }
    await page.keyboard.press('r');
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("驳回")`);
    await page.click(`${visibleModal} .reason-presets .ant-tag-checkable:has-text("含联系方式")`);
    await page.fill(`${visibleModal} textarea`, '请勿在公开内容里留微信号');
    await shot(page, '14c_内容审核_拒绝原因', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("驳回")`);
      await page.waitForSelector('.ant-message-success:has-text("已驳回")');
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);
    await page.waitForTimeout(500);
    for (let i = 0; i < 3; i++) await page.locator('.rv-item .ant-checkbox-input').nth(i).check();
    await page.click('.rv-toolbar button:has-text("批量驳回")');
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("驳回选中的 3 条")`);
    await page.click(`${visibleModal} .reason-presets .ant-tag-checkable:has-text("含广告或引流")`);
    await shot(page, '14d_内容审核_批量拒绝', { fullPage: false });
    await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);
    await page.waitForTimeout(300);
    if (WRITES) {
      await page.click('.rv-toolbar button:has-text("批量通过")');
      await page.waitForSelector('.ant-modal-confirm-title:has-text("通过选中的 3 条")');
      await page.click('.ant-modal-confirm-btns button:has-text("全部通过")');
      await page.waitForSelector('.ant-message-success:has-text("已批量通过")');
    }
    await page.goto(`${BASE}/review?type=avatar`);
    await page.waitForSelector('.rv-item');
    await shot(page, '14e_内容审核_头像');
    await page.goto(`${BASE}/review?status=rejected`);
    await page.waitForSelector('.rv-item');
    await shot(page, '14f_内容审核_已拒绝记录');

    // 15 举报处理
    await page.goto(`${BASE}/review?tab=reports`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, '15_社区_举报处理');
    await page.locator('.ant-table-row').first().locator('button:has-text("下架")').click();
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("下架")`);
    await page.click(`${visibleModal} .ant-segmented-item:has-text("7 天")`);
    await page.fill(`${visibleModal} textarea`, '多人举报，内容属实');
    await shot(page, '15b_举报_下架并禁言', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("下架")`);
      await page.waitForSelector('.ant-message-success:has-text("已下架")');
      await page.goto(`${BASE}/review?tab=reports&status=handled`);
      await page.waitForSelector('.ant-table-row');
      await shot(page, '15c_举报_已下架记录');
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);
    await page.goto(`${BASE}/review?tab=reports`);
    await page.waitForSelector('.ant-table-row');
    await page.locator('.ant-table-row').nth(2).click();
    await page.waitForSelector('.ant-drawer-title:has-text("举报 #")');
    await shot(page, '15d_举报_详情', { fullPage: false });
    await page.keyboard.press('Escape');

    // 16 动态管理
    await page.goto(`${BASE}/review?tab=posts`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, '16_社区_动态管理');
    await page.locator('.ant-table-row:has-text("下雨天也要跑") button:has-text("查看")').click();
    await page.waitForSelector('.ant-drawer-title:has-text("动态 #")');
    await page.waitForTimeout(400);
    await shot(page, '16b_动态详情_图片与运动', { fullPage: false });
    await page.click('.ant-drawer-extra button:has-text("下架")');
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("下架动态")`);
    await page.click(`${visibleModal} .reason-presets .ant-tag-checkable:has-text("侵犯他人隐私或肖像")`);
    await shot(page, '16c_下架动态', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("下架")`);
      await page.waitForSelector('.ant-message-success:has-text("已下架")');
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);
    await page.goto(`${BASE}/review?tab=posts&review_status=pending`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, '16d_动态管理_待审核筛选');

    // 17 敏感词与审核设置
    await page.goto(`${BASE}/review?tab=settings`);
    await page.waitForSelector('text=打分规则与结果');
    await page.click('.panel:has(h2:has-text("审核词")) button:has-text("批量粘贴")');
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("批量粘贴审核词")`);
    await page.fill(`${visibleModal} textarea`, '约炮\n代购\n刷步数\n代跑\n内部价');
    await shot(page, '17b_敏感词_批量粘贴', { fullPage: false });
    await page.click(`${visibleModal} .ant-modal-footer button:has-text("添加")`);
    await page.locator('.panel:has(h2:has-text("拦截词")) .word-box .ant-tag:has-text("裸聊") .ant-tag-close-icon').click();
    await page.fill('input[aria-label="自动放行线"]', '40');
    await page.locator('input[aria-label="自动放行线"]').blur();
    await page.fill('textarea[aria-label="试一试文本"]', '周末一起跑，有内部价跑鞋，wx：shoes_8848');
    await page.waitForTimeout(400);
    await shot(page, '17_社区_敏感词与审核设置');
    if (WRITES) {
      await page.click('button:has-text("保存设置")');
      await page.waitForSelector('.ant-message-success:has-text("已保存")');
    }

    // 18 组局管理
    await page.goto(`${BASE}/community`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, '18_社区_组局管理');
    await page.locator('.ant-table-row button:has-text("取消组局"):not([disabled])').first().click();
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("取消「")`);
    await page.click(`${visibleModal} .reason-presets .ant-tag-checkable:has-text("天气或场地原因")`);
    await shot(page, '18b_取消组局', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("确认取消")`);
      await page.waitForSelector('.ant-message-success:has-text("已取消")');
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("返回")`);

    // 19 赛事管理
    await page.goto(`${BASE}/community?tab=races`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, '19_社区_赛事管理');
    await page.click('button:has-text("新建赛事")');
    await page.waitForSelector('.ant-drawer-title:has-text("新建赛事")');
    await page.click('.ant-drawer .ant-radio-button-wrapper:has-text("线下赛")');
    await page.fill('#title', '前滩公园 5K 夜跑赛');
    await page.fill('#distance_km', '5');
    await page.fill('#capacity', '300');
    await page.fill('#description', '前滩公园环线两圈，现场计时，完赛发奖牌。');
    await page.fill('#medal_key', 'race_2026_qiantan5k');
    await page.fill('#medal_name', '前滩夜跑奖牌');
    await page.fill('#place_name', '前滩公园东门');
    await page.waitForSelector('.race-place svg[role=img] path[fill-opacity]');
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(400);
    const mapBox = await page.locator('.race-place svg[role=img]').first().boundingBox();
    await page.mouse.click(mapBox.x + mapBox.width * 0.55, mapBox.y + mapBox.height * 0.6);
    await page.waitForFunction(() => document.querySelector('#lat')?.value);
    await page.waitForTimeout(500);
    await shot(page, '19b_新建线下赛_地图选点', { fullPage: false });
    if (WRITES) {
      await page.click('.ant-drawer-extra button:has-text("保存")');
      await page.waitForSelector('.ant-message-success:has-text("赛事已")');
    } else await page.click('.ant-drawer-extra button:has-text("取消")');
    await page.locator('.ant-table-row:has-text("城市 10K") button:has-text("编辑")').click();
    await page.waitForSelector('.ant-drawer-title:has-text("编辑「城市 10K")');
    await page.waitForTimeout(300);
    await shot(page, '19c_编辑线上赛', { fullPage: false });
    await page.click('.ant-drawer-extra button:has-text("取消")');
    await page.waitForTimeout(300);
    await page.locator('.ant-table-row:has-text("双十一") button:has-text("报名名单")').click();
    await page.waitForSelector('.ant-drawer-title:has-text("报名名单")');
    await page.waitForSelector('.ant-drawer .ant-table-row');
    await shot(page, '19d_报名名单_线下赛', { fullPage: false });
    await page.locator('.ant-drawer .ant-table-row button:has-text("标记完赛"):not([disabled])').first().click();
    await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("标记完赛")`);
    await page.fill('input[aria-label="完赛用时"]', '1:02:30');
    await shot(page, '19e_标记完赛', { fullPage: false });
    if (WRITES) {
      await page.click(`${visibleModal} .ant-modal-footer button:has-text("标记完赛")`);
      await page.waitForSelector('.ant-message-success:has-text("完赛")');
    } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);

    // 20 总览 (M-01)
    await page.goto(`${BASE}/`);
    await page.waitForSelector('text=待审核内容');
    await page.mouse.move(1200, 5);
    await shot(page, '20_总览_待审核');
  }

  async function communityRoles() {
    // reviewer: 内容审核 (队列 / 举报 / 动态) only — no 敏感词设置, no 组局与赛事
    const rv = await session('amei');
    const nav = async (label) => rv.page.locator(`nav.side a[aria-label="${label}"]`).count();
    if (!(await nav('内容审核'))) problems.push('[amei] 内容审核 menu missing');
    if (await nav('组局与赛事')) problems.push('[amei] 组局与赛事 menu visible to reviewer');
    await rv.page.goto(`${BASE}/review?tab=settings`);
    await rv.page.waitForSelector('.rv-item');
    if (await rv.page.locator('.ant-segmented-item:has-text("敏感词与审核设置")').count()) problems.push('[amei] 敏感词与审核设置 tab visible to reviewer');
    await shot(rv.page, '21_审核员视角_内容审核', { fullPage: false });
    await rv.page.goto(`${BASE}/review?tab=reports`);
    await rv.page.waitForSelector('.ant-table-row');
    await rv.page.goto(`${BASE}/community?tab=races`);
    await rv.page.waitForSelector('text=没有权限');
    await shot(rv.page, '21b_审核员视角_赛事403', { fullPage: false });
    await rv.ctx.close();

    // ops: 审核 + 组局与赛事, but not 敏感词设置
    const ops = await session('xiaolin');
    await ops.page.goto(`${BASE}/review`);
    await ops.page.waitForSelector('.rv-item');
    if (await ops.page.locator('.ant-segmented-item:has-text("敏感词与审核设置")').count()) problems.push('[xiaolin] 敏感词与审核设置 tab visible to ops');
    await ops.page.goto(`${BASE}/community?tab=races`);
    await ops.page.waitForSelector('.ant-table-row');
    await ops.ctx.close();

    // narrow
    const m = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
    const mp = await m.newPage();
    mp.on('pageerror', (e) => problems.push(`[mobile] pageerror: ${e.message}`));
    await mp.goto(`${BASE}/login`);
    await mp.fill('#username', 'admin');
    await mp.fill('#password', PASSWORD);
    await mp.click('button[type=submit]');
    await mp.waitForSelector('h1.page-title');
    await mp.goto(`${BASE}/review`);
    await mp.waitForSelector('.rv-item');
    await shot(mp, '22_窄屏_内容审核');
    await m.close();
  }

  if (!ONLY_COMMUNITY && !ONLY_AI) await perksShots({ browser, session, shot, BASE, problems, writes: WRITES });
  if (!ONLY_COMMUNITY && !ONLY_AI) await merchantShots({ browser, session, shot, BASE, problems, writes: WRITES });
  return finish();

  async function finish() {
    await browser.close();
    if (problems.length) {
      console.error('\nProblems:\n' + [...new Set(problems)].join('\n'));
      process.exit(1);
    }
    console.log('\nNo console errors or warnings.');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
