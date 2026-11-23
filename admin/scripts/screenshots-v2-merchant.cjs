// V2 第四批「本地生活与商户」· 商户 / 场馆 / 订场 / 核销结算 / 核销台 / 核销记录 / 总览待办 screenshots
// (called from screenshots-v2.cjs; `ONLY=merchant pnpm run screenshots:v2`). Names start at MERCHANT_FROM
// (default below, after the 投放 / 联名活动 / 能量商城 shots) and carry the page name.
// The 核销台 is also run at phone width as merchant staff (`shop`), with Chromium's fake camera playing a
// QR video of a fresh coupon payload (needs ffmpeg; skipped with a note if it is missing).
// Writes (staff account, QR rotate, refund, confirm / paid, redeem) are skipped with NO_WRITES=1.
const path = require('path');
const os = require('os');
const fs = require('fs');
const { execFileSync } = require('child_process');
const { chromium } = require('playwright');

const FROM = Number(process.env.MERCHANT_FROM || 39);

module.exports = async function merchantShots({ browser, session, shot, BASE, problems, writes }) {
  const no = (k) => String(FROM + k);
  const visibleModal = '.ant-modal-wrap:not([style*="display: none"])';
  const drawer = '.ant-drawer-open .ant-drawer-content';
  const closeDrawer = async (page) => {
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);
  };

  const { ctx, page } = await session('admin');

  // ---------------------------------------------------------------- 商户
  await page.goto(`${BASE}/merchant/merchants`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(0)}_商户_列表`);
  await page.goto(`${BASE}/merchants?status=reviewing`); // short link from 总览 keeps the filter
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(0)}b_商户_资质审核筛选`, { fullPage: false });

  await page.goto(`${BASE}/merchant/merchants?id=2`);
  await page.waitForSelector(`${drawer} .mer-drop`);
  await shot(page, `${no(1)}_商户_详情`, { fullPage: false });
  await page.click(`${drawer} button:has-text("查看完整号码")`);
  await page.waitForSelector(`${drawer} :text("已记入审计日志")`);
  await page.click(`${drawer} button:has-text("新建员工账号")`);
  await page.waitForSelector(`${visibleModal} input#username`);
  await page.fill(`${visibleModal} input#username`, 'paoye_front');
  await page.fill(`${visibleModal} input#password`, 'front-desk-2026');
  await shot(page, `${no(1)}b_商户_完整号码与新建员工账号`, { fullPage: false });
  if (writes) {
    await page.click(`${visibleModal} button:has-text("创建")`);
    await page.waitForSelector('.ant-modal-confirm-success');
    await page.click('.ant-modal-confirm-success button');
    await page.waitForSelector(`${drawer} .ant-tag:has-text("paoye_front")`);
  } else {
    await page.click(`${visibleModal} button:has-text("取消")`);
  }
  await closeDrawer(page);

  await page.goto(`${BASE}/merchant/merchants?status=reviewing`);
  await page.waitForSelector('.ant-table-row');
  await page.locator('.ant-table-row', { hasText: '城市攀岩馆' }).locator('button:has-text("编辑")').click();
  await page.waitForSelector(`${drawer} .img-up`);
  await page.waitForTimeout(500);
  await shot(page, `${no(2)}_商户_编辑`, { fullPage: false });
  await closeDrawer(page);
  await page.click('button:has-text("新建商户")');
  await page.waitForSelector(`${drawer} input#name`);
  await page.fill(`${drawer} input#contact_phone`, '1380000');
  await page.click(`${drawer} .ant-drawer-extra button:has-text("保存")`);
  await page.waitForSelector(`${drawer} .ant-form-item-explain-error`);
  await page.waitForTimeout(300);
  await shot(page, `${no(2)}b_商户_新建_校验`, { fullPage: false });
  await closeDrawer(page);

  // ---------------------------------------------------------------- 场馆
  await page.goto(`${BASE}/merchant/venues`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(3)}_场馆_列表`);
  await page.goto(`${BASE}/merchant/venues?id=8`);
  await page.waitForSelector(`${drawer} .qr-box img`);
  await page.waitForSelector(`${drawer} .ant-table-row`);
  await shot(page, `${no(4)}_场馆_二维码与历任馆主`, { fullPage: false });
  const [download] = await Promise.all([page.waitForEvent('download'), page.click(`${drawer} button:has-text("下载 PNG")`)]);
  const file = path.join(os.tmpdir(), `venue-qr-${Date.now()}.png`);
  await download.saveAs(file);
  const head = fs.readFileSync(file).subarray(0, 8).toString('hex');
  if (head !== '89504e470d0a1a0a') problems.push(`[admin] 场馆二维码下载不是 PNG（${download.suggestedFilename()}）`);
  else console.log('downloaded', download.suggestedFilename(), fs.statSync(file).size, 'bytes');
  fs.rmSync(file, { force: true });
  await page.click(`${drawer} button:has-text("换码")`);
  await page.waitForSelector('.ant-modal-confirm');
  await shot(page, `${no(4)}b_场馆_换码确认`, { fullPage: false });
  if (writes) {
    const before = await page.textContent(`${drawer} .qr-payload`);
    await page.click('.ant-modal-confirm button:has-text("确认换码")');
    await page.waitForFunction((b) => document.querySelector('.ant-drawer-open .qr-payload')?.textContent !== b, before);
  } else {
    await page.click('.ant-modal-confirm button:has-text("取消")');
  }
  await page.click(`${drawer} .ant-drawer-extra button:has-text("编辑")`);
  await page.waitForSelector('.ant-drawer-open .race-place svg');
  await page.waitForTimeout(600);
  await shot(page, `${no(5)}_场馆_编辑`, { fullPage: false });
  await closeDrawer(page);
  await closeDrawer(page);
  await page.click('button:has-text("新建场馆")');
  await page.waitForSelector('.ant-drawer-open .race-place svg');
  await page.waitForTimeout(500);
  const svg = page.locator('.ant-drawer-open .race-place svg').first();
  const box = await svg.boundingBox();
  await page.mouse.click(box.x + box.width * 0.55, box.y + box.height * 0.45);
  await page.waitForFunction(() => !!document.querySelector('.ant-drawer-open input#lat')?.value);
  await page.fill('.ant-drawer-open input#name', '滨江跑团 · 篮球场');
  await page.waitForTimeout(400);
  await shot(page, `${no(5)}b_场馆_新建_地图选点`, { fullPage: false });
  await closeDrawer(page);

  // ---------------------------------------------------------------- 订场
  await page.goto(`${BASE}/merchant/bookings`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(6)}_订场_列表`);
  await page.locator('.ant-table-row', { hasText: '馆主价' }).first().locator('td').first().click();
  await page.waitForSelector(`${drawer} .ant-descriptions`);
  await shot(page, `${no(6)}b_订场_详情`, { fullPage: false });
  await closeDrawer(page);
  await page.goto(`${BASE}/merchant/bookings?status=completed`);
  await page.waitForSelector('.ant-table-row');
  await page.locator('.ant-table-row').first().locator('button:has-text("退款")').click();
  await page.waitForSelector(`${visibleModal} textarea`);
  await page.fill(`${visibleModal} textarea`, '场馆空调故障，当天无法正常使用，全额退款');
  await shot(page, `${no(7)}_订场_退款第1步`, { fullPage: false });
  await page.click(`${visibleModal} button:has-text("下一步")`);
  await page.waitForSelector('.ant-modal-confirm:has-text("再次确认退款")');
  await page.waitForTimeout(300);
  await shot(page, `${no(7)}b_订场_退款第2步`, { fullPage: false });
  if (writes) {
    await page.click('.ant-modal-confirm button:has-text("确认退款")');
    await page.waitForSelector('.ant-message-success');
  } else {
    await page.click('.ant-modal-confirm button:has-text("取消")');
  }

  // ---------------------------------------------------------------- 核销结算
  await page.goto(`${BASE}/merchant/settlement`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(8)}_核销结算`);
  await page.click('.ant-segmented-item:has-text("风控作废（次）")');
  await page.waitForTimeout(500);
  await shot(page, `${no(8)}b_核销结算_风控作废`, { fullPage: false });
  await page.goto(`${BASE}/merchant/settlement?status=draft`);
  await page.waitForSelector('.ant-table-row');
  await page.locator('.ant-table-row').first().locator('button:has-text("查看")').click();
  await page.waitForSelector(`${drawer} .ant-table-row`);
  await page.click(`${drawer} .ant-segmented-item:has-text("风控作废")`);
  await page.waitForTimeout(300);
  await shot(page, `${no(9)}_结算单_详情`, { fullPage: false });
  await page.click(`${drawer} .ant-drawer-extra button:has-text("确认")`);
  await page.waitForSelector('.ant-modal-confirm');
  await shot(page, `${no(9)}b_结算单_确认`, { fullPage: false });
  if (writes) {
    await page.click('.ant-modal-confirm button:has-text("确认结算单")');
    await page.waitForSelector(`${drawer} .ant-drawer-extra button:has-text("标记已付款")`);
    await page.click(`${drawer} .ant-drawer-extra button:has-text("标记已付款")`);
    await page.waitForSelector('.ant-modal-confirm:has-text("标记为已付款")');
    await page.click('.ant-modal-confirm button:has-text("已线下打款，标记")');
    await page.waitForSelector(`${drawer} .ant-tag:has-text("已付款")`);
  } else {
    await page.click('.ant-modal-confirm button:has-text("取消")');
  }
  await closeDrawer(page);
  await page.goto(`${BASE}/merchant/settlement`);
  await page.click('button:has-text("手动生成结算单")');
  await page.waitForSelector(`${visibleModal} .ant-picker`);
  await shot(page, `${no(9)}c_结算单_手动生成`, { fullPage: false });
  if (writes) {
    await page.click(`${visibleModal} button:has-text("生成")`);
    await page.waitForSelector('.ant-message-error, .ant-message-success'); // last week already exists → 409
  }
  await page.keyboard.press('Escape');

  // ---------------------------------------------------------------- 核销记录 / 核销台（运营代核销）/ 总览
  await page.goto(`${BASE}/merchant/redemptions`);
  await page.waitForSelector('.ant-table-row');
  await shot(page, `${no(10)}_核销记录`);
  await page.goto(`${BASE}/merchant/redeem`);
  await page.waitForSelector('.redeem-card');
  if (writes) {
    await page.fill('input[aria-label="券码"]', 'J4H8TTKC');
    await page.press('input[aria-label="券码"]', 'Enter');
    await page.waitForSelector('.redeem-result.ok');
  }
  await shot(page, `${no(11)}_核销台_运营代核销`, { fullPage: false });
  await page.goto(`${BASE}/`);
  await page.waitForSelector('.todo-row');
  await shot(page, `${no(12)}_总览_商户待办`);
  await ctx.close();

  // ---------------------------------------------------------------- 运营视角: 没有结算
  {
    const ops = await session('xiaolin');
    await ops.page.goto(`${BASE}/merchant/merchants`);
    await ops.page.waitForSelector('.ant-table-row');
    await ops.page.goto(`${BASE}/merchant/settlement`);
    await ops.page.waitForSelector('.ant-result-403');
    await shot(ops.page, `${no(13)}_运营视角_核销结算403`, { fullPage: false });
    await ops.ctx.close();
  }

  // ---------------------------------------------------------------- 商户对接 (shop) at phone width, fake camera
  let camBrowser = null;
  let y4m = null;
  try {
    execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' });
    const QR = require('qrcode');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'redeem-cam-'));
    const png = path.join(dir, 'qr.png');
    y4m = path.join(dir, 'qr.y4m');
    // Coupon 83 (P2X7MNQR, 跑野运动馆) in mock mode; the payload is valid for 60 seconds.
    await QR.toFile(png, process.env.REDEEM_PAYLOAD || `LPC.83.${Math.floor(Date.now() / 1000)}.fakeCamSig`, { width: 360, margin: 4 });
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-loop', '1', '-i', png, '-vf', 'pad=640:480:(ow-iw)/2:(oh-ih)/2:white,format=yuv420p', '-t', '3', '-r', '10', y4m]);
    camBrowser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-video-capture=${y4m}`] });
  } catch (e) {
    console.log('fake camera unavailable, scanning step skipped:', e.message);
  }
  const phoneBrowser = camBrowser || browser;
  const phone = await phoneBrowser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'zh-CN', permissions: camBrowser ? ['camera'] : [] });
  const p = await phone.newPage();
  p.on('console', (m) => (m.type() === 'error' || m.type() === 'warning') && problems.push(`[shop] console.${m.type()}: ${m.text()}`));
  p.on('pageerror', (e) => problems.push(`[shop] pageerror: ${e.message}`));
  await p.goto(`${BASE}/login`);
  await p.fill('#username', 'shop');
  await p.fill('#password', process.env.STAFF_PASSWORD || 'loopland');
  await p.click('button[type=submit]');
  await p.waitForSelector('.redeem-card'); // merchant staff land on 核销台
  if (!p.url().endsWith('/merchant/redeem')) problems.push(`[shop] landed on ${p.url()} instead of /merchant/redeem`);
  const nav = await p.$$eval('.mer-nav .ant-segmented-item-label', (els) => els.map((e) => e.textContent));
  if (nav.join(',') !== '核销台,场馆预订,结算单,核销记录') problems.push(`[shop] unexpected nav: ${nav.join(',')}`);
  await shot(p, `${no(14)}_商户对接_核销台_窄屏`);
  if (camBrowser && writes) {
    await p.click('button:has-text("扫码核销")');
    await p.waitForSelector('.redeem-result', { timeout: 20_000 });
    await shot(p, `${no(14)}b_商户对接_扫码核销成功`, { fullPage: false });
    await p.click('.redeem-result button:has-text("手输下一张")');
  }
  for (const [code, name] of [
    ['3NB6KDFE', 'c_商户对接_今天没运动'],
    ['6LK4JHGF', 'd_商户对接_不是本店的券'],
  ]) {
    await p.fill('input[aria-label="券码"]', code);
    await p.press('input[aria-label="券码"]', 'Enter');
    await p.waitForSelector('.redeem-result');
    await shot(p, `${no(14)}${name}`, { fullPage: false });
    await p.click('.redeem-result button:has-text("手输券码")');
  }
  await p.goto(`${BASE}/merchant/bookings`);
  await p.waitForSelector('.ant-table-row');
  await shot(p, `${no(15)}_商户对接_场馆预订_窄屏`, { fullPage: false });
  await p.goto(`${BASE}/merchant/settlement`);
  await p.waitForSelector('.ant-table-row');
  await shot(p, `${no(15)}b_商户对接_结算单_窄屏`);
  await p.goto(`${BASE}/merchant/merchants`);
  await p.waitForSelector('.ant-result-403');
  await p.goto(`${BASE}/`);
  await p.waitForSelector('.redeem-card');
  await phone.close();
  if (camBrowser) await camBrowser.close();
  if (y4m) fs.rmSync(path.dirname(y4m), { recursive: true, force: true });
};
