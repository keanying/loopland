// Glyphs the admin needs that the App's set (glyphs.ts, generated from app/lib/widgets/l_icons.dart) does
// not have yet. Same rules as the App: 24×24 grid, round caps and joins, stroked at ~1.8, `O cx cy r` for a
// full circle, an "off" line cut out of the shape it crosses. `proto`: copied from the admin prototype
// (docs/资料包/05_原型源文件/Admin*.dc.html); the rest are drawn to match.
//
// To add one to the App later, copy it into LIcons (l_icons.dart) and run `pnpm run glyphs`; then delete
// it here (a name in both sets is a type error in Glyph.tsx).
import type { GlyphDef } from './glyphs';

const S = (d: string) => ({ d });
const F = (d: string) => ({ d, fill: true });
const X = (d: string, extra = 0) => ({ d, cut: true, ...(extra ? { extra } : {}) });
const XF = (d: string) => ({ d, fill: true, cut: true });

const PHONE = 'M7 3h10v18H7zM11 18h2';
const EYE = 'M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6zO12 12 2.8';
const CLOUD = 'M6.5 18.5a4.5 4.5 0 0 1-.5-9 6 6 0 0 1 11.6 1.6 3.8 3.8 0 0 1-.1 7.4z';

export const ADMIN_GLYPHS = {
  // ── 侧栏（管理端原型）────────────────────────────────────────
  /** 总览：四个圆角方块。 */
  grid: {
    parts: [
      S(
        'M5 3h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z' +
          'M16 3h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z' +
          'M5 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2z' +
          'M16 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-3a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2z',
      ),
    ],
    proto: true,
  },
  /** 内容审核：文件 + 勾。 */
  review: { parts: [S('M6 3h9l4 4v14H6zM9 13l2 2 4-4')], proto: true },
  /** 玩法配置：三条滑杆（App 的 sliders 是两条）。 */
  tune: { parts: [S('M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12O16 6 2O10 12 2O18 18 2')], proto: true },
  logout: { parts: [S('M10 4H5v16h5M14 8l4 4-4 4M18 12H9')], proto: true },
  /** 页头铃铛（管理端原型，铃舌是半圆；App 的 bell 是一道横线）。 */
  notice: { parts: [S('M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0')], proto: true },
  /** 系统配置：六齿齿轮。 */
  gear: {
    parts: [
      S(
        'M10.07 5.69 10.44 3.14h3.12l.37 2.55A6.6 6.6 0 0 1 16.5 7.17l2.39-.96 1.57 2.71-2.03 1.6A6.6 6.6 0 0 1 18.43 13.48' +
          'l2.03 1.6-1.57 2.71-2.39-.96A6.6 6.6 0 0 1 13.93 18.31l-.37 2.55h-3.12l-.37-2.55A6.6 6.6 0 0 1 7.5 16.83' +
          'l-2.39.96-1.57-2.71 2.03-1.6A6.6 6.6 0 0 1 5.57 10.52L3.54 8.92l1.57-2.71 2.39.96A6.6 6.6 0 0 1 10.07 5.69zO12 12 2.8',
      ),
    ],
  },

  // ── 箭头与状态 ──────────────────────────────────────────────
  /** 分页「向前 / 向后 5 页」。 */
  chevronsLeft: { parts: [S('M12 6l-6 6 6 6M18 6l-6 6 6 6')] },
  chevronsRight: { parts: [S('M6 6l6 6-6 6M12 6l6 6-6 6')] },
  arrowUp: { parts: [S('M12 19V5M6 11l6-6 6 6')], proto: true },
  arrowDown: { parts: [S('M12 5v14M6 13l6 6 6-6')], proto: true },
  /** 两道勾：全部已读。 */
  checkAll: { parts: [S('M2.5 12.5l4.5 4.5 8.5-9.5M12 16l1 1 8.5-9.5')] },
  /** 风险 / 警告：三角 + 感叹号（原型风险分旁边的三角）。 */
  warning: { parts: [S('M12 3.8 21 19.5H3zM12 9.6v4.4'), F('O12 16.7 1.05')], proto: true },
  alertFilled: { parts: [F('O12 12 9'), X('M12 7.4v5.4'), XF('O12 16.4 1.2')] },
  infoFilled: { parts: [F('O12 12 9'), X('M12 11v5.4'), XF('O12 7.6 1.2')] },
  closeCircleFilled: { parts: [F('O12 12 9'), X('M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6')] },
  power: { parts: [S('M12 3.5v7.5M7.3 6.4a7.5 7.5 0 1 0 9.4 0')] },

  // ── 风控（管理端原型 AdminRisk 的告警类型）─────────────────────
  /** 速度异常：半个表盘。 */
  gauge: { parts: [S('M12 13l4-4M4 18a8 8 0 1 1 16 0')], proto: true },
  /** 模拟定位：定位针里一个叉。 */
  pinX: { parts: [S('M12 21s-6-6-6-11a6 6 0 0 1 12 0c0 5-6 11-6 11zM9.5 7.5l5 5M14.5 7.5l-5 5')], proto: true },
  /** 轨迹瞬移：一段轨迹突然跳出去。 */
  jump: { parts: [S('M4 18c4 0 4-8 8-8M14 6h6v6M20 6l-8 8')], proto: true },
  /** 设备数据缺失：传感器芯片 + 一道斜线。 */
  sensorOff: { parts: [S('M8 3h8v4H8zM8 17h8v4H8zM6 7h12v10H6z'), X('M4 4l16 16', 2.4), S('M4 4l16 16')], proto: true },
  /** 多账号同设备：一台手机两侧在震。 */
  deviceShared: { parts: [S(PHONE + 'M3 8v8M21 8v8')], proto: true },
  phone: { parts: [S(PHONE)] },
  /** 设备被改过：手机里一个感叹号。 */
  phoneAlert: { parts: [S(PHONE + 'M12 7v5'), F('O12 14.6 1.05')] },

  // ── 运营与商户 ──────────────────────────────────────────────
  /** 怪兽（原型地图图层「怪兽」）。 */
  monster: { parts: [S('M5 18V9a7 7 0 0 1 14 0v9l-2.5-2-2.5 2-2-2-2 2-2.5-2z'), F('O9.5 10 1.1O14.5 10 1.1')], proto: true },
  /** 补给站：一杯饮料（原型投放类型「补给站」）。 */
  cup: { parts: [S('M6 8h10v9a4 4 0 0 1-4 4h-2a4 4 0 0 1-4-4zM16 10h2a2 2 0 0 1 0 4h-2')], proto: true },
  /** 商品：购物袋。 */
  bag: { parts: [S('M5.5 8h13l-1 12.5h-11zM9 10V7a3 3 0 0 1 6 0v3')] },
  /** 开放平台：尖括号。 */
  code: { parts: [S('M8 7l-5 5 5 5M16 7l5 5-5 5M13.5 5l-3 14')] },
  key: { parts: [S('O8 15.5 4.5M11.2 12.3 19.5 4M16.3 7.2l2.5 2.5M14 9.5l2 2')] },
  /** 签到码。 */
  qr: { parts: [S('M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14v6M17.5 14H20M17.5 17.5V20H20')] },
  /** 金额（¥）：打款、支付。 */
  yuan: { parts: [S('O12 12 8.5M8.8 7.6 12 11.4l3.2-3.8M12 11.4V17M9 12.6h6M9 15h6')] },
  idCard: { parts: [S('M3 5.5h18v13H3zO8.5 10.8 2.1M5 16.2c.7-1.6 1.9-2.4 3.5-2.4s2.8.8 3.5 2.4M14.5 10h4M14.5 13.5h3')] },
  cloud: { parts: [S(CLOUD)] },
  clipboard: { parts: [S('M8.5 5H6v16h12V5h-2.5M9 3h6v4H9z')] },

  // ── 审核与图片 ──────────────────────────────────────────────
  eye: { parts: [S(EYE)] },
  eyeOff: { parts: [S(EYE), X('M4 4l16 16', 2.4), S('M4 4l16 16')] },
  /** 打码：3×3 马赛克。 */
  mosaic: { parts: [S('M4 4h16v16H4z'), F('M4 4h5.3v5.3H4zM14.7 4H20v5.3h-5.3zM9.3 9.3h5.4v5.4H9.3zM4 14.7h5.3V20H4zM14.7 14.7H20V20h-5.3z')] },
} satisfies Record<string, GlyphDef>;
