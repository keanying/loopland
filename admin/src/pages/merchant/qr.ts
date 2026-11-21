// Venue check-in QR (LPV.<id>.<签名>): rendered in the browser with the pinned `qrcode` library
// (loaded on demand) and downloadable as a print-ready PNG with the venue name under the code.

export async function qrDataUrl(text: string, width = 360): Promise<string> {
  const QR = await import('qrcode');
  return QR.toDataURL(text, { width, margin: 1, errorCorrectionLevel: 'M', color: { dark: '#141414', light: '#ffffff' } });
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('二维码生成失败'));
    img.src = src;
  });
}

/** A 900 × 1100 PNG: title, QR (1 px margin) and the venue name, for printing at the front desk. */
export async function downloadVenueQr(text: string, venueName: string, venueId: number): Promise<void> {
  const qr = await loadImage(await qrDataUrl(text, 720));
  const W = 900;
  const H = 1120;
  const canvas = document.createElement('canvas');
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('浏览器不支持导出图片');
  const font = "-apple-system, BlinkMacSystemFont, 'PingFang SC', 'Noto Sans SC', 'Microsoft YaHei', sans-serif";
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = '#141414';
  ctx.textAlign = 'center';
  ctx.font = `800 52px ${font}`;
  ctx.fillText('圈圈 Loopland · 场馆签到', W / 2, 96);
  ctx.drawImage(qr, (W - 720) / 2, 140, 720, 720);
  ctx.font = `700 42px ${font}`;
  const name = venueName.length > 18 ? venueName.slice(0, 17) + '…' : venueName;
  ctx.fillText(name, W / 2, 940);
  ctx.fillStyle = '#6a6a70';
  ctx.font = `400 30px ${font}`;
  ctx.fillText('打开圈圈 App 扫一扫，或用手机相机扫码签到', W / 2, 1000);
  ctx.fillText('每天 1 次 · 签到得能量和馆主积分', W / 2, 1046);
  const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/png'));
  if (!blob) throw new Error('导出图片失败');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  // ASCII name: some browsers (headless Chromium among them) drop non-ASCII download names to "download".
  a.download = `loopland_venue_${venueId}_checkin_qr.png`;
  a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    a.remove();
    URL.revokeObjectURL(a.href);
  }, 2000);
}
