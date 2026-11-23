// 站内信分类图标和空状态的两张小插画（原型插画风格：细黑线）。
// 线条图标统一走 Glyph（和 App 的 LIcons 同一套图形）。这里原来的 IconBell / IconBag / … 已并进去：
// 铃铛是 notice（管理端原型的页头铃铛），bag、code、review、checkAll、eye 进了 glyphsAdmin.ts（上传卡片用的是下面的 DoodlePicture），
// flag、receipt、megaphone、arrowRight、link、trash、close 用 App 的同名图形。
import type { MessageCategory } from '../api/types';
import { Glyph, type GlyphName } from './Glyph';

const CATEGORY_GLYPH: Partial<Record<MessageCategory, GlyphName>> = {
  product: 'bag',
  promotion: 'flag',
  settlement: 'receipt',
  openapi: 'code',
  review: 'review',
};

/** One icon per 站内信 category. */
export function CategoryIcon({ category, size = 20 }: { category: MessageCategory; size?: number }) {
  return <Glyph name={CATEGORY_GLYPH[category] ?? 'megaphone'} size={size} />;
}

/**
 * Empty inbox: the mascot from the 总览 greeting card, sitting next to an opened, empty envelope.
 * Thin black strokes, slightly wobbly, no decoration.
 */
export function DoodleInbox({ width = 184, className }: { width?: number; className?: string }) {
  return (
    <svg
      width={width}
      height={(width * 120) / 184}
      viewBox="0 0 184 120"
      fill="none"
      stroke="#141414"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={className}
    >
      <path d="M8 108 C 46 100 96 114 176 104" />
      {/* mascot */}
      <path d="M22 98 c-5 -22 10 -37 29 -37 c15 0 25 12 24 29 c-1 8 -8 12 -18 12 h-22 c-7 0 -11 -1 -13 -4z" fill="#FFFFFF" />
      <circle cx="44" cy="50" r="17" fill="#FFFFFF" />
      <circle cx="38" cy="47" r="3.8" fill="#FFFFFF" />
      <circle cx="39" cy="48" r="1.5" fill="#141414" />
      <circle cx="51" cy="47" r="3.8" fill="#FFFFFF" />
      <circle cx="52" cy="48" r="1.5" fill="#141414" />
      <path d="M41 57 q4 2.5 8 0" />
      <path d="M33 101 l-3 7.5 M57 101 l3 7.5" />
      <path d="M22 96 c-9 3 -15 0 -18 -7 c-1.5 -4.5 1.5 -7.5 4.5 -6" />
      {/* arm reaching to the envelope */}
      <path d="M72 84 c8 -2 15 -6 22 -12" />
      {/* opened envelope, tilted, empty */}
      <g transform="rotate(-7 128 74)">
        <path d="M98 62 l30 -20 31 20" fill="#FFFFFF" />
        <path d="M97.5 62 h62 l-0.5 38 h-61 z" fill="#FFFFFF" />
        <path d="M98 63 l30.5 21 30.5 -21" />
        <path d="M100 99 l21 -17 M157 99 l-20.5 -17" />
      </g>
    </svg>
  );
}

/** No image yet: a hand-drawn photo frame (hills and a sun) with an up arrow, for the upload card. */
export function DoodlePicture({ width = 46 }: { width?: number }) {
  return (
    <svg width={width} height={(width * 40) / 46} viewBox="0 0 46 40" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M4.5 9.5 c6 -0.6 21 -0.8 27 -0.3 M4.5 9.5 c-0.5 7 -0.4 18 0.3 25 c8 0.6 22 0.5 29 -0.2 c0.4 -4 0.4 -8 0.2 -12" />
      <path d="M6.5 31 c3 -4 6 -8 9 -9.5 c2 1.5 3 3.2 4.5 4.8 c2 -2.2 3.5 -3.6 5 -4.3 c2 1.6 4 4.5 6 7.5" />
      <path d="M13.5 15.5 a2.6 2.6 0 1 0 0.1 0" />
      <path d="M39 20 V4 M34.5 8.2 L39 3.5 l4.5 4.7" />
    </svg>
  );
}
