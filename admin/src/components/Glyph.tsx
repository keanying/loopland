// 圈圈的图标：和 App（app/lib/widgets/l_icons.dart 的 LIcons）同一套画法、同一批图形。
//
//   <Glyph name="plus" />                 16 px（按钮里的默认大小）
//   <Glyph name="pin" size="1em" />       跟着字号走（夹在文字里）
//   <Glyph name="quan" size={20} title="圈圈" />   有 title 才读给读屏软件，否则 aria-hidden
//
// 颜色是 currentColor。线宽跟 App 一样随尺寸变：24 px 时 1.8，小图标略粗，大图标略细。
// 外层是 <span class="anticon">，所以 Button、Tag、Input 前缀、下拉菜单里的间距和对齐跟 Ant Design 自己的图标一样。
import { forwardRef, useId, type CSSProperties, type HTMLAttributes } from 'react';
import { EM_STROKE, GLYPHS, glyphNodes, strokeUnits, type GlyphName } from './glyphKit';

export type { GlyphName };

export interface GlyphProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'color'> {
  name: GlyphName;
  /** Pixels, or '1em' to follow the font size. Default 16 (Ant Design buttons). */
  size?: number | '1em';
  color?: string;
  /** Accessible name; without it the icon is decorative (aria-hidden). */
  title?: string;
}

export const Glyph = forwardRef<HTMLSpanElement, GlyphProps>(function Glyph({ name, size = 16, color, title, className, style, ...rest }, ref) {
  const uid = useId().replace(/:/g, '');
  const g = GLYPHS[name];
  const sw = size === '1em' ? EM_STROKE : strokeUnits(size);
  const s: CSSProperties | undefined = color ? { color, ...style } : style;
  const labelled = !!title || !!rest['aria-label'];
  return (
    <span
      ref={ref}
      role={labelled ? 'img' : undefined}
      aria-label={title}
      aria-hidden={labelled ? undefined : true}
      {...rest}
      className={`anticon glyph glyph-${name}` + (className ? ' ' + className : '')}
      style={s}
    >
      <svg width={size} height={size} viewBox="0 0 24 24" focusable="false" aria-hidden="true" style={{ overflow: 'visible' }}>
        {title && <title>{title}</title>}
        {glyphNodes(g, sw, uid)}
      </svg>
    </span>
  );
});

export default Glyph;
