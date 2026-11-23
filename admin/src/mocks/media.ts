// Mock of V2 第六批「管理端图片上传」POST /admin/v1/media (docs/api/v2-6-管理端图片上传与站内信.md).
// The uploaded file comes back as a data: URL, so previews (and the forms that save the URL) work without a server.
// Type check by content (magic bytes), 10 MB limit, purpose × role table and the 500 / day quota mirror the contract.
// To see the 503 path in mock mode, upload a file whose name contains "mock-503".
import { ApiError } from '../api/client';
import type { AdminRole, MediaPurpose, UploadedMedia } from '../api/types';
import { merchantOf } from './merchant';

type Ctx = { m: RegExpMatchArray; q: URLSearchParams; body: Record<string, unknown>; adminId: number; role: AdminRole };
type Handler = (ctx: Ctx) => unknown;

const MAX_BYTES = 10 * 1024 * 1024;
const DAILY_LIMIT = 500;

/** Who may upload for which purpose (403 forbidden otherwise). */
const PURPOSE_ROLES: Record<MediaPurpose, AdminRole[]> = {
  product: ['merchant'],
  promotion_banner: ['admin', 'ops'],
  venue_cover: ['admin', 'ops', 'merchant'],
  merchant_license: ['admin', 'ops'],
  campaign_banner: ['admin', 'ops'],
  shop_item: ['admin', 'ops'],
};

function fail(status: number, code: string, message: string): never {
  throw new ApiError(status, code, message);
}

/** jpg / png / webp / heic by magic bytes; null when it is none of them. */
async function sniff(file: Blob): Promise<string | null> {
  const b = new Uint8Array(await file.slice(0, 16).arrayBuffer());
  const ascii = (from: number, to: number) => String.fromCharCode(...b.slice(from, to));
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b[0] === 0x89 && ascii(1, 4) === 'PNG') return 'image/png';
  if (ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image/webp';
  if (ascii(4, 8) === 'ftyp' && ['heic', 'heix', 'hevc', 'mif1', 'msf1'].includes(ascii(8, 12))) return 'image/heic';
  return null;
}

function dataUrl(file: Blob, mime: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).replace(/^data:[^;,]*/, `data:${mime}`));
    r.onerror = () => reject(new ApiError(500, 'internal', '读取文件失败'));
    r.readAsDataURL(file);
  });
}

async function size(file: Blob): Promise<{ width: number; height: number }> {
  try {
    const bmp = await createImageBitmap(file);
    const s = { width: bmp.width, height: bmp.height };
    bmp.close();
    return s;
  } catch {
    return { width: 0, height: 0 }; // e.g. HEIC, which the browser cannot decode
  }
}

let mediaSeq = 3000;
const usedToday = new Map<string, number>();

export function mediaRoutes(): [string, RegExp, Handler][] {
  return [
    ['POST', /^\/media$/, async ({ body, adminId, role }): Promise<UploadedMedia> => {
      const form = body as unknown as FormData;
      if (typeof form?.get !== 'function') fail(400, 'invalid_body', '需要 multipart/form-data');
      const purpose = String(form.get('purpose') ?? '') as MediaPurpose;
      if (!(purpose in PURPOSE_ROLES)) fail(400, 'invalid_body', `purpose 取值错误：${purpose || '（空）'}`);
      if (!PURPOSE_ROLES[purpose].includes(role)) fail(403, 'forbidden', '当前角色不能上传这类图片');
      if (role === 'merchant' && merchantOf(adminId) === null) fail(403, 'forbidden', '这个商户账号还没有绑定商户');
      const file = form.get('file');
      if (!(file instanceof Blob) || file.size === 0) fail(400, 'invalid_body', '缺少文件');
      if (file instanceof File && file.name.includes('mock-503')) fail(503, 'media_unavailable', '图片存储暂不可用，请稍后再试');
      const mime = await sniff(file);
      if (!mime) fail(400, 'unsupported_media', '只支持 jpg / png / webp / heic 图片');
      if (file.size > MAX_BYTES) fail(413, 'file_too_large', '图片不能超过 10 MB');
      const key = `${adminId}:${new Date().toISOString().slice(0, 10)}`;
      const n = usedToday.get(key) ?? 0;
      if (n >= DAILY_LIMIT) fail(429, 'rate_limited', '今天上传的图片已达 500 张上限，明天再试');
      usedToday.set(key, n + 1);
      const [url, dim] = await Promise.all([dataUrl(file, mime), size(file)]);
      return { id: ++mediaSeq, url, ...dim };
    }],
  ];
}
