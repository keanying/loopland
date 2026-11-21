// V2 第四批「本地生活与商户」· 投放 / 联名活动 / 能量商城 screenshots (called from screenshots-v2.cjs,
// `ONLY=perks pnpm run screenshots:v2`). Names start at PERKS_FROM (default below) and carry the page name.
// Writes (create a drop / launch a campaign / pause) are skipped with NO_WRITES=1 (real backend you care about).

const FROM = Number(process.env.PERKS_FROM || 31);

module.exports = async function perksShots({ browser, session, shot, BASE, problems, writes }) {
  const no = (k) => String(FROM + k);
  const visibleModal = '.ant-modal-wrap:not([style*="display: none"])';
  const drawer = '.ant-drawer-open';

  const pickOption = async (page, selectId, text) => {
    await page.waitForTimeout(400); // let a modal / drawer finish opening
    await page.locator(`#${selectId}`).last().click({ force: true });
    const opt = page.locator('.ant-select-dropdown:visible .ant-select-item-option', { hasText: text }).first();
    await opt.waitFor({ state: 'visible' });
    await page.waitForTimeout(250); // dropdown open animation
    await opt.click();
  };

  const { ctx, page } = await session('admin');

  // ---- 投放
  await page.goto(`${BASE}/merchant/drops`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(0)}_投放_列表`);
  await page.goto(`${BASE}/merchant/drops?merchant_id=1`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(0)}b_投放_按商户筛选`, { fullPage: false });

  // 新建投放 wizard: 补给站 for 青柠茶铺
  await page.click('button:has-text("新建投放")');
  await page.waitForSelector(`${drawer} .ant-drawer-title:has-text("新建投放")`);
  await page.waitForSelector(`${drawer} .type-card`);
  await shot(page, `${no(1)}_投放_新建_类型与商户`, { fullPage: false });
  await page.click(`${drawer} button:has-text("下一步")`);
  await page.waitForSelector(`${drawer} #place`);
  await page.fill('#place', '滨江大道 · 泰同栈');
  await page.waitForLoadState('networkidle');
  const box = await page.locator(`${drawer} .map-wrap > svg[role=img]`).boundingBox();
  await page.mouse.click(box.x + box.width * 0.48, box.y + box.height * 0.42);
  await page.waitForFunction(() => !!document.querySelector('#lat')?.value);
  await shot(page, `${no(1)}b_投放_新建_位置`, { fullPage: false });
  await page.click(`${drawer} button:has-text("下一步")`);
  await page.waitForSelector(`${drawer} #perk_title`);
  await page.fill('#perk_title', '跑满 5 km 送冰柠檬茶');
  await page.fill('#perk_value_text', '免费');
  await page.fill('#perk_description', '限泰同栈店，每人每天 1 次');
  await page.click(`${drawer} .ant-tag-checkable:has-text("14 天")`);
  await shot(page, `${no(1)}c_投放_新建_权益与App预览`, { fullPage: false });
  await page.click(`${drawer} button:has-text("下一步")`);
  await page.waitForSelector(`${drawer} .cap-stepper`);
  await page.click(`${drawer} button[aria-label="增加 10"]`);
  await page.click(`${drawer} .ant-radio-wrapper:has-text("平台付商户")`);
  await shot(page, `${no(1)}d_投放_新建_发放与结算`, { fullPage: false });
  if (writes) {
    await page.click(`${drawer} button:has-text("创建投放")`);
    await page.waitForSelector('.ant-message-success');
    await page.waitForSelector(`.ant-table-row:has-text("滨江大道 · 泰同栈")`);
    await shot(page, `${no(1)}e_投放_创建后`, { fullPage: false });
  } else await page.click(`${drawer} .ant-drawer-footer button:has-text("取消")`);

  // 据点: pick a venue instead of a point
  await page.goto(`${BASE}/merchant/drops`);
  await page.waitForSelector('.ant-table-row');
  await page.click('button:has-text("新建投放")');
  await page.waitForSelector(`${drawer} .type-card`);
  await page.click(`${drawer} .type-card:has-text("据点")`);
  await pickOption(page, 'merchant_id', '跑野运动馆');
  await page.click(`${drawer} button:has-text("下一步")`);
  await pickOption(page, 'venue_id', '跑野运动馆 · 东方路');
  await page.waitForSelector(`${drawer} svg title:has-text("跑野运动馆 · 东方路")`, { state: 'attached' });
  await shot(page, `${no(1)}f_投放_新建据点_选场馆`, { fullPage: false });
  await page.click(`${drawer} .ant-drawer-footer button:has-text("取消")`);

  // validation: skip required fields
  await page.click('button:has-text("新建投放")');
  await page.waitForSelector(`${drawer} .type-card`);
  await page.waitForTimeout(300);
  await page.click(`${drawer} button:has-text("下一步")`);
  await page.waitForSelector(`${drawer} .ant-form-item-explain-error`);
  await page.click(`${drawer} .ant-drawer-footer button:has-text("取消")`);

  // edit + pause / resume
  await page.goto(`${BASE}/merchant/drops?status=active`);
  await page.waitForSelector('.ant-table-row');
  await page.locator('.ant-table-row').first().locator('button:has-text("编辑")').click();
  await page.waitForSelector(`${drawer} .ant-drawer-title:has-text("编辑投放")`);
  await page.click(`${drawer} .ant-steps-item:has-text("权益")`);
  await page.waitForSelector(`${drawer} #perk_title`);
  await shot(page, `${no(2)}_投放_编辑`, { fullPage: false });
  await page.click(`${drawer} .ant-drawer-footer button:has-text("取消")`);
  await page.locator('.ant-table-row').first().locator('button:has-text("暂停")').click();
  await page.waitForSelector('.ant-modal-confirm-title');
  await shot(page, `${no(2)}b_投放_暂停确认`, { fullPage: false });
  if (writes) {
    await page.click('.ant-modal-confirm-btns button:has-text("暂停")');
    await page.waitForSelector('.ant-message-success');
    await page.goto(`${BASE}/merchant/drops?status=paused`);
    await page.waitForSelector('.ant-table-row');
    await shot(page, `${no(2)}c_投放_已暂停`, { fullPage: false });
  } else await page.click('.ant-modal-confirm-btns button:has-text("取消")');

  // ---- 联名活动
  await page.goto(`${BASE}/merchant/campaigns`);
  await page.waitForSelector('.bc-card');
  await shot(page, `${no(3)}_联名活动`);
  await page.locator('.bc-card').first().locator('button:has-text("详情")').click();
  await page.waitForSelector(`${drawer} .ant-table`);
  await page.waitForLoadState('networkidle');
  await shot(page, `${no(3)}b_联名活动_详情`, { fullPage: false });
  await page.click(`${drawer} .ant-drawer-close`);
  await page.waitForSelector(drawer, { state: 'detached' }).catch(() => undefined);
  await page.locator('.bc-card').first().locator('button:has-text("暂停")').click();
  await page.waitForSelector('.ant-modal-confirm-title');
  await shot(page, `${no(3)}c_联名活动_暂停确认`, { fullPage: false });
  await page.click('.ant-modal-confirm-btns button:has-text("取消")');
  const launchCard = page.locator('.bc-card.scheduled').first();
  if (await launchCard.count()) {
    await launchCard.locator('button:has-text("提前上线")').click();
    await page.waitForSelector('.ant-modal-confirm-title');
    await shot(page, `${no(3)}d_联名活动_提前上线确认`, { fullPage: false });
    if (writes) {
      await page.click('.ant-modal-confirm-btns button:has-text("提前上线")');
      await page.waitForSelector('.ant-message-success');
    } else await page.click('.ant-modal-confirm-btns button:has-text("取消")');
  } else problems.push('no scheduled brand campaign to launch');
  await page.click('button:has-text("新建联名活动")');
  await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("新建联名活动")`);
  await pickOption(page, 'merchant_id', '街角便利');
  await page.fill(`${visibleModal} #title`, '街角便利 · 元旦夜跑补给');
  await page.fill(`${visibleModal} #description`, '元旦前后夜跑经过门店补给站，领热饮和暖宝宝');
  await page.fill(`${visibleModal} #store_count`, '25');
  await page.fill(`${visibleModal} #target_redemptions`, '8000');
  await page.fill(`${visibleModal} #investment_yuan`, '18000');
  await shot(page, `${no(3)}e_联名活动_新建`, { fullPage: false });
  if (writes) {
    await page.click(`${visibleModal} .ant-modal-footer button:has-text("保存")`);
    await page.waitForSelector('.ant-message-success');
  } else await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);

  // ---- 能量商城
  await page.goto(`${BASE}/merchant/shop`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(4)}_能量商城`);
  await page.locator('.ant-table-row').first().locator('button:has-text("编辑")').click();
  await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("编辑")`);
  await page.fill(`${visibleModal} #name`, '霓虹领地皮肤 · 冬季版');
  await shot(page, `${no(4)}b_能量商城_编辑皮肤`, { fullPage: false });
  await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);
  await page.goto(`${BASE}/merchant/shop?type=avatar_frame`);
  await page.waitForSelector('.ant-table-row');
  await page.click('button:has-text("新建商品")');
  await page.waitForSelector(`${visibleModal} .ant-modal-title:has-text("新建商品")`);
  await pickOption(page, 'type', '头像框');
  await page.fill(`${visibleModal} #key`, 'frame_bad key');
  await page.click(`${visibleModal} .ant-modal-footer button:has-text("保存")`);
  await page.waitForSelector(`${visibleModal} .ant-form-item-explain-error`);
  await shot(page, `${no(4)}c_能量商城_新建_校验`, { fullPage: false });
  await page.click(`${visibleModal} .ant-modal-footer button:has-text("取消")`);

  // ---- 地图与领地: 补给站 layer
  await page.goto(`${BASE}/territories`);
  await page.waitForSelector('.ant-checkbox-group[aria-label="图层"]');
  await page.waitForLoadState('networkidle');
  if (await page.locator('.ant-checkbox-group[aria-label="图层"] .ant-checkbox-wrapper', { hasText: '补给站' }).count()) {
    await page.waitForSelector('svg title:has-text("补给站")', { state: 'attached' });
    await shot(page, `${no(5)}_地图_补给站图层`, { fullPage: false });
  } else problems.push('no 补给站 layer on the map page');
  await ctx.close();

  // ---- roles
  const ops = await session('xiaolin');
  await ops.page.goto(`${BASE}/merchant/drops`);
  await ops.page.waitForSelector('.ant-table-row');
  await shot(ops.page, `${no(6)}_运营视角_投放`, { fullPage: false });
  await ops.ctx.close();
  if (!process.env.SKIP_REVIEWER) {
    const rv = await session('amei');
    await rv.page.goto(`${BASE}/merchant/shop`);
    await rv.page.waitForSelector('text=没有权限');
    await shot(rv.page, `${no(6)}b_审核员视角_能量商城403`, { fullPage: false });
    await rv.ctx.close();
  }

  // narrow
  const m = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1 });
  const mp = await m.newPage();
  mp.on('pageerror', (e) => problems.push(`[mobile] pageerror: ${e.message}`));
  await mp.goto(`${BASE}/login`);
  await mp.fill('#username', 'admin');
  await mp.fill('#password', process.env.ADMIN_PASSWORD || 'loopland');
  await mp.click('button[type=submit]');
  await mp.waitForSelector('h1.page-title');
  await mp.goto(`${BASE}/merchant/campaigns`);
  await mp.waitForSelector('.bc-card');
  await shot(mp, `${no(7)}_窄屏_联名活动`);
  await m.close();
};
