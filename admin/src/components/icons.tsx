// Line icons in the prototype's style (docs/资料包/05_原型源文件/Admin*.dc.html): 24px viewBox, 1.8px stroke,
// round caps and joins, currentColor. Paths marked「原型」are copied from the prototype; the rest are drawn to
// match. Plus two small doodles for empty states in the prototype's illustration style (thin black strokes).
import type { CSSProperties, ReactNode } from 'react';
import type { MessageCategory } from '../api/types';

interface IconProps {
  size?: number;
  className?: string;
  style?: CSSProperties;
  strokeWidth?: number;
}

function Line({ size = 20, className, style, strokeWidth = 1.8, children }: IconProps & { children: ReactNode }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      className={'line-icon' + (className ? ' ' + className : '')}
      style={style}
    >
      {children}
    </svg>
  );
}

/** 原型：页头铃铛 */
export const IconBell = (p: IconProps) => (
  <Line {...p}>
    <path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0" />
  </Line>
);

/** 商品：购物袋 */
export const IconBag = (p: IconProps) => (
  <Line {...p}>
    <path d="M5.5 8h13l-1 12.5h-11z" />
    <path d="M9 10V7a3 3 0 0 1 6 0v3" />
  </Line>
);

/** 原型：旗子（活动） */
export const IconFlag = (p: IconProps) => (
  <Line {...p}>
    <path d="M5 21V4h11l-2 4 2 4H5" />
  </Line>
);

/** 结算：小票 */
export const IconReceipt = (p: IconProps) => (
  <Line {...p}>
    <path d="M6 3h12v18l-2-1.4-2 1.4-2-1.4-2 1.4-2-1.4-2 1.4z" />
    <path d="M9 8h6M9 12h6M9 16h3" />
  </Line>
);

/** 开放平台：尖括号 */
export const IconCode = (p: IconProps) => (
  <Line {...p}>
    <path d="M8 7l-5 5 5 5M16 7l5 5-5 5M13.5 5l-3 14" />
  </Line>
);

/** 原型：审核（文件 + 勾） */
export const IconReview = (p: IconProps) => (
  <Line {...p}>
    <path d="M6 3h9l4 4v14H6z" />
    <path d="M9 13l2 2 4-4" />
  </Line>
);

/** 系统通知：喇叭 */
export const IconMegaphone = (p: IconProps) => (
  <Line {...p}>
    <path d="M4 10v4h3l6 4.5v-13L7 10z" />
    <path d="M16.5 9.5a3.5 3.5 0 0 1 0 5M19 7a7 7 0 0 1 0 10" />
  </Line>
);

/** 原型：对勾；全部已读用两道 */
export const IconCheckAll = (p: IconProps) => (
  <Line {...p}>
    <path d="M2.5 12.5l4.5 4.5 8.5-9.5M12 16l1 1 8.5-9.5" />
  </Line>
);

/** 原型：向右箭头 */
export const IconArrowRight = (p: IconProps) => (
  <Line {...p}>
    <path d="M5 12h14M13 6l6 6-6 6" />
  </Line>
);

/** 上传：图片框 + 向上箭头 */
export const IconImageUpload = (p: IconProps) => (
  <Line {...p}>
    <path d="M20 13v5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h7" />
    <path d="M4 17l4.5-5 3.5 3.5 2.5-2.5L20 18" />
    <path d="M18 9V2.5M15.2 5.3L18 2.5l2.8 2.8" />
  </Line>
);

/** 链接（粘贴图片网址） */
export const IconLink = (p: IconProps) => (
  <Line {...p}>
    <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" />
    <path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
  </Line>
);

/** 查看大图 */
export const IconEye = (p: IconProps) => (
  <Line {...p}>
    <path d="M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6z" />
    <circle cx="12" cy="12" r="2.8" />
  </Line>
);

/** 删除 */
export const IconTrash = (p: IconProps) => (
  <Line {...p}>
    <path d="M4 7h16M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10.5 11v5M13.5 11v5" />
  </Line>
);

/** 原型：关闭 */
export const IconClose = (p: IconProps) => (
  <Line {...p}>
    <path d="M6 6l12 12M18 6 6 18" />
  </Line>
);

/** One icon per 站内信 category. */
export function CategoryIcon({ category, ...p }: IconProps & { category: MessageCategory }) {
  switch (category) {
    case 'product':
      return <IconBag {...p} />;
    case 'promotion':
      return <IconFlag {...p} />;
    case 'settlement':
      return <IconReceipt {...p} />;
    case 'openapi':
      return <IconCode {...p} />;
    case 'review':
      return <IconReview {...p} />;
    default:
      return <IconMegaphone {...p} />;
  }
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
