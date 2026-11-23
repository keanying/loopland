// Ant Design's own icons (select arrows, pagination, message / modal status icons …) drawn with our glyphs.
//
// 1. Where Ant Design takes an icon for the whole app (ConfigProvider: modal / drawer close button, image
//    preview), we pass a <Glyph>: ANTD_ICON_CONFIG. (Not for Tag / Alert: a closeIcon in their ConfigProvider
//    config also makes every Tag / Alert closable.)
// 2. Everything else is rendered inside Ant Design with its built-in icon set. Those icons keep their
//    `anticon-<name>` class; installAntdIconSkin() paints our glyph over each one with a CSS mask (same path
//    data, stroke 2.2 for the 12–16 px they are drawn at) and hides Ant Design's SVG. Icons not listed in SKIN
//    (loading spinner, table sort carets, image preview toolbar, Empty illustrations …) stay as they are.
import type { ConfigProviderProps } from 'antd';
import { Glyph } from './Glyph';
import { glyphSvgString, type GlyphName } from './glyphKit';

const close = <Glyph name="close" size={16} />;

export const ANTD_ICON_CONFIG: Pick<ConfigProviderProps, 'modal' | 'drawer' | 'image'> = {
  modal: { closeIcon: close },
  drawer: { closeIcon: close },
  image: { preview: { closeIcon: <Glyph name="close" size={18} /> } },
};

/** `anticon-<class>` (Ant Design's icon name) → our glyph. Outlined and filled variants share a class. */
const SKIN: Record<string, GlyphName> = {
  down: 'chevronDown',
  up: 'chevronUp',
  left: 'back',
  right: 'chevronRight',
  'double-left': 'chevronsLeft',
  'double-right': 'chevronsRight',
  'swap-right': 'arrowRight',
  close: 'close',
  check: 'check',
  plus: 'plus',
  minus: 'minus',
  search: 'search',
  calendar: 'calendar',
  'clock-circle': 'clock',
  eye: 'eye',
  'eye-invisible': 'eyeOff',
  copy: 'copy',
  edit: 'pencil',
  delete: 'trash',
  ellipsis: 'moreH',
  upload: 'upload',
  'check-circle': 'checkCircleFilled',
  'close-circle': 'closeCircleFilled',
  'info-circle': 'infoFilled',
  'exclamation-circle': 'alertFilled',
  warning: 'warning',
};

/** In these places Ant Design draws the outlined variant; keep it outlined. */
const OUTLINED: [scope: string, cls: string, glyph: GlyphName][] = [
  ['.ant-alert-with-description', 'check-circle', 'checkCircle'],
  ['.ant-alert-with-description', 'close-circle', 'block'],
  ['.ant-alert-with-description', 'info-circle', 'info'],
  ['.ant-alert-with-description', 'exclamation-circle', 'alert'],
];

const SKIN_STROKE = 2.2;

function rule(selector: string, glyph: GlyphName): string {
  const url = `url("data:image/svg+xml,${encodeURIComponent(glyphSvgString(glyph, SKIN_STROKE))}")`;
  return (
    `${selector}{background-color:currentColor;-webkit-mask:${url} center/100% 100% no-repeat;mask:${url} center/100% 100% no-repeat}` +
    `${selector}>svg{visibility:hidden}`
  );
}

export function antdIconSkinCss(): string {
  return [
    ...Object.entries(SKIN).map(([cls, g]) => rule(`.anticon.anticon-${cls}`, g)),
    ...OUTLINED.map(([scope, cls, g]) => rule(`${scope} .anticon.anticon-${cls}`, g)),
  ].join('\n');
}

/** Adds the CSS once (call before the first render). */
export function installAntdIconSkin() {
  if (document.getElementById('glyph-antd-skin')) return;
  const el = document.createElement('style');
  el.id = 'glyph-antd-skin';
  el.textContent = antdIconSkinCss();
  document.head.appendChild(el);
}
