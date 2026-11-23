import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:path_parsing/path_parsing.dart';

import '../core/theme.dart';

/// 圈圈自己的图标。
///
/// 线条图标画在 24×24 网格上：圆头圆角，24 px 时线宽约 1.8 px，小尺寸略加粗，
/// 大尺寸略收细，和原型（docs/资料包/05_原型源文件）里内联的 SVG 图标同一套画法。
/// 原型里有的图标直接取原型的路径（[LGlyph.proto] 为 true），没有的按同样的规矩补画。
///
/// 用法和 [Icon] 一样：`LIcon(LIcons.flag)`，不给 size / color 时取 [IconTheme]，
/// 所以放进 IconButton、ListTile、按钮、Chip 里都会跟着主题走。
///
/// 路径里除了标准 SVG 命令，还可以写 `O cx cy r` 表示一个整圆。
class LGlyph {
  const LGlyph(this.name, this.parts, {this.proto = false});

  /// 名字（只用于调试和图标总览）。
  final String name;

  /// 按顺序绘制的各个部分。镂空部分（[_X] / [_XF]）擦掉前面已经画好的部分。
  final List<LPart> parts;

  /// 取自原型（含旋转、镜像、拼合原型里的部件）。
  final bool proto;

  @override
  String toString() => 'LGlyph($name)';

  /// 线宽（网格单位）：24 px 时 1.8；小于 24 px 时加粗一点，保证 12–16 px 也看得清；
  /// 大图标稍细一点，免得显得笨重。
  static double strokeUnits(double size) {
    if (size <= 24) return 1.8 + (24 - size).clamp(0.0, 12.0) * 0.04;
    return 1.8 - (size - 24).clamp(0.0, 32.0) * 0.008;
  }
}

/// 图标的一个部分：描边、填充，或从已画部分里镂空。
class LPart {
  const LPart._(this.d, {this.fill = false, this.cut = false, this.extra = 0});

  /// 路径（SVG path data，外加 `O cx cy r` 整圆）。
  final String d;
  final bool fill;

  /// 镂空：用 dstOut 把已经画好的部分擦掉（比如实心圆里的对勾、双环之间的缝）。
  final bool cut;

  /// 描边镂空时比正常线宽多出的宽度（网格单位）。
  final double extra;
}

/// 描边。
class _S extends LPart {
  const _S(super.d) : super._();
}

/// 填充（边缘再描一圈细线，让尖角变圆润）。
class _F extends LPart {
  const _F(super.d) : super._(fill: true);
}

/// 按描边镂空，线宽 = 正常线宽 + [extra]。
class _X extends LPart {
  const _X(super.d, [double extra = 0]) : super._(cut: true, extra: extra);
}

/// 按填充镂空。
class _XF extends LPart {
  const _XF(super.d) : super._(fill: true, cut: true);
}

/// 全部图标。语义相同的 Material 图标共用一个（比如各种 chevron_right）。
abstract final class LIcons {
  // ── 导航与基础 ────────────────────────────────────────────
  static const back = LGlyph('back', [_S('M15 6l-6 6 6 6')], proto: true);
  static const chevronRight = LGlyph('chevronRight', [_S('M9 6l6 6-6 6')], proto: true);
  static const chevronDown = LGlyph('chevronDown', [_S('M6 9l6 6 6-6')], proto: true);
  static const chevronUp = LGlyph('chevronUp', [_S('M6 15l6-6 6 6')], proto: true);
  static const arrowRight = LGlyph('arrowRight', [_S('M5 12h14M13 6l6 6-6 6')], proto: true);

  /// 发送（原型 AI 页的发送按钮就是向右的箭头）。
  static const send = LGlyph('send', [_S('M4.5 12h14M12.5 5.5l6.5 6.5-6.5 6.5')], proto: true);
  static const close = LGlyph('close', [_S('M6 6l12 12M18 6 6 18')], proto: true);
  static const plus = LGlyph('plus', [_S('M12 5v14M5 12h14')], proto: true);
  static const minus = LGlyph('minus', [_S('M5 12h14')], proto: true);
  static const plusCircle = LGlyph('plusCircle', [_S('O12 12 8.5M12 8.2v7.6M8.2 12h7.6')]);
  static const minusCircle = LGlyph('minusCircle', [_S('O12 12 8.5M8.2 12h7.6')]);
  static const moreH = LGlyph('moreH', [_F('O5 12 1.6O12 12 1.6O19 12 1.6')], proto: true);
  static const moreV = LGlyph('moreV', [_F('O12 5 1.6O12 12 1.6O12 19 1.6')], proto: true);
  static const check = LGlyph('check', [_S('M5 12l5 5 9-10')], proto: true);
  static const checkCircle = LGlyph('checkCircle', [_S('O12 12 8.5M8 12.3l2.8 2.8 5.2-5.6')]);
  static const checkCircleFilled = LGlyph('checkCircleFilled', [_F('O12 12 9'), _X('M8 12.3l2.8 2.8 5.2-5.6')]);
  static const ring = LGlyph('ring', [_S('O12 12 8.5')]);
  static const dot = LGlyph('dot', [_F('O12 12 9')]);
  static const search = LGlyph('search', [_S('O11 11 6.5M20 20l-4-4')], proto: true);
  static const sliders = LGlyph('sliders', [_S('M4 7h10M18 7h2M4 17h4M12 17h8O16 7 2O10 17 2')], proto: true);
  static const info = LGlyph('info', [_S('O12 12 8.5M12 11v5'), _F('O12 7.9 1.1')]);
  static const alert = LGlyph('alert', [_S('O12 12 8.5M12 7.6v5'), _F('O12 16.2 1.1')]);
  static const block = LGlyph('block', [_S('O12 12 8.5M6 6l12 12')]);

  // ── 地图与位置 ────────────────────────────────────────────
  /// 领地（底栏）。
  static const map = LGlyph('map', [_S('M9 4 3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14')], proto: true);

  /// 圈下的一块地（不规则多边形，和地图上的领地同形）。
  static const plot = LGlyph('plot', [_S('M5 8.5 12.5 4l6.5 4.5-1.5 9-8.5 2.5L4 15z')]);
  static const pin = LGlyph('pin', [_S('M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12zO12 9 2.5')], proto: true);
  static const pinFilled =
      LGlyph('pinFilled', [_F('M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12z'), _XF('O12 9 2.6')], proto: true);
  static const pinCheck =
      LGlyph('pinCheck', [_S('M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12zM9.2 9.2l1.9 1.9 3.6-3.7')], proto: true);
  static const pinOff = LGlyph('pinOff', [
    _S('M12 21s-7-6.2-7-12a7 7 0 0 1 14 0c0 5.8-7 12-7 12z'),
    _X('M4 4l16 16', 2.4),
    _S('M4 4l16 16'),
  ]);
  static const locate = LGlyph('locate', [_S('O12 12 4.5M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3'), _F('O12 12 1.2')], proto: true);

  /// 导航过去（箭头）。
  static const navigate = LGlyph('navigate', [_S('M12 3.5l7 16.5-7-4-7 4z')]);
  static const compass = LGlyph('compass', [_S('O12 12 8.5M15.2 8.8l-2.2 5-4.2 1.4 2.2-5z')], proto: true);

  /// 一条路线：起点圆点 + 弯弯的轨迹。
  static const route = LGlyph('route', [_S('M7.6 16.6C9.6 9.5 12 6 15 6c3 0 5 2 5 5 0 4-4 6-8 6O6 18 2')], proto: true);

  /// 接力（原型「跑团接力」的心电线）。
  static const relay = LGlyph('relay', [_S('M3 12h5l3-6 3 12 3-6h4')], proto: true);
  static const layers = LGlyph('layers', [_S('M12 4 3.5 8.5 12 13l8.5-4.5zM3.5 12.5 12 17l8.5-4.5M3.5 16.5 12 21l8.5-4.5')]);
  static const mountain = LGlyph('mountain', [_S('M3 20l6-10 4 6 3-4 5 8z')], proto: true);
  static const ruler = LGlyph('ruler', [_S('M3 8h18v8H3zM7 8v3M11 8v4.5M15 8v3M19 8v2')]);

  /// 卫星定位信号。
  static const signal = LGlyph('signal', [
    _S('M8.6 15.4a5 5 0 0 1 0-7M15.4 8.4a5 5 0 0 1 0 7M5.8 18.2a9 9 0 0 1 0-12.6M18.2 5.6a9 9 0 0 1 0 12.6'),
    _F('O12 12 2'),
  ]);

  /// 环线：一个圈 + 圈上跑着的人（品牌标志里的空心圈和紫点）。
  static const loopRoute = LGlyph('loopRoute', [_S('O12 13 7.5'), _XF('O12 5.5 3.6'), _F('O12 5.5 2.2')]);

  /// 双环 oo（品牌标志的两个圈）。
  static const loops = LGlyph('loops', [_S('O8 12 5'), _X('O16 12 5', 2.2), _S('O16 12 5')]);

  // ── 刷新与时间 ────────────────────────────────────────────
  static const refresh = LGlyph('refresh', [_S('M20 12a8 8 0 1 1-3-6.2M20 4v5h-5')], proto: true);
  static const replay = LGlyph('replay', [_S('M4 12a8 8 0 1 0 3-6.2M4 4v5h5')], proto: true);
  static const history = LGlyph('history', [_S('M4.2 13a8 8 0 1 0 2.2-6.7M4 4v4.4h4.4M12 8v4.3l2.8 1.8')]);
  static const clock = LGlyph('clock', [_S('O12 12 8.5M12 7.5V12l3 2')]);
  static const timer = LGlyph('timer', [_S('O12 13 8M12 9v4l3 2M9 2h6')], proto: true);
  static const hourglass = LGlyph('hourglass', [
    _S('M6.5 3h11M6.5 21h11M8 3v2.5c0 3 4 4 4 6.5s-4 3.5-4 6.5V21M16 3v2.5c0 3-4 4-4 6.5s4 3.5 4 6.5V21'),
    _F('M10 18.6h4l-2-2z'),
  ]);
  static const calendar = LGlyph('calendar', [_S('M4 6h16v14H4zM4 10.5h16M8.5 3v4.5M15.5 3v4.5')]);
  static const calendarCheck = LGlyph('calendarCheck', [_S('M4 6h16v14H4zM4 10.5h16M8.5 3v4.5M15.5 3v4.5M9 15.2l2 2 4-4')]);

  // ── 运动 ──────────────────────────────────────────────────
  static const run = LGlyph('run', [_S('O14 5 1.8M10 21l2.5-5.5 3 2.5v4M7 12.5l3-3.5 4.5 1.5 2.5 3M14.2 10.4l-1.7 5.1')], proto: true);
  static const walk = LGlyph('walk', [_S('O12 4.5 1.8M12 8v6l-3 7M12 14l3 7M9 11l3-2 3 2')], proto: true);
  static const bike = LGlyph('bike', [_S('O6 16 3.5O18 16 3.5M6 16l4-7h5l3 7M9 9h3')], proto: true);
  static const tennis = LGlyph('tennis', [_S('O12 12 8M5 7c4 2 4 8 0 10M19 7c-4 2-4 8 0 10')], proto: true);
  static const dumbbell = LGlyph('dumbbell', [_S('M3 10v4M6 8v8M18 8v8M21 10v4M6 12h12')], proto: true);
  static const yoga = LGlyph('yoga', [_S('O12 5 1.8M12 8v6M5 11l7 2 7-2M8 21l4-7 4 7')], proto: true);
  static const rope = LGlyph('rope', [_S('M6 4v5M18 4v5M6 9c0 8 12 8 12 0')], proto: true);

  /// 据点 / 场馆。
  static const venue = LGlyph('venue', [_S('M4 21V8l8-5 8 5v13M9 21v-6h6v6')], proto: true);
  static const store = LGlyph('store', [_S('M4 10v10h16V10M3 10l2-6h14l2 6zM9 20v-5h6v5')], proto: true);

  /// 玩法（原型地图右侧「玩法」）。
  static const gamepad = LGlyph('gamepad', [
    _S('M6 9h4M8 7v4M7 4h10a5 5 0 0 1 5 5v2a5 5 0 0 1-5 5h-1l-2 3h-4l-2-3H7a5 5 0 0 1-5-5V9a5 5 0 0 1 5-5z'),
    _F('O15 10.2 1.1O18 8 1.1'),
  ], proto: true);

  /// 轨迹绘画。
  static const scribble = LGlyph('scribble', [_S('M4 20c4-8 8 0 12-8 2-4 4-6 4-8')], proto: true);

  /// 跑步伙伴（原型「跑步伙伴」：冒芽的小果子）。
  static const buddy = LGlyph('buddy', [_S('M12 20c-5 0-8-3-8-7s3-6 8-6 8 2 8 6-3 7-8 7zM12 7c0-3 2-5 5-5')], proto: true);

  /// 建城（原型地图右侧「建城」）。
  static const castle = LGlyph('castle', [_S('M4 21V9h3V5h3v3h4V5h3v4h3v12zM10 21v-5h4v5')], proto: true);
  static const egg = LGlyph('egg', [
    _S('M12 3c-3.6 0-6.5 5.8-6.5 10.4A6.5 6.5 0 0 0 12 20.5a6.5 6.5 0 0 0 6.5-7.1C18.5 8.8 15.6 3 12 3z'),
    _F('O9.9 10.6 1.2O14.2 14.8 1.5'),
  ]);
  static const watch = LGlyph('watch', [_S('O12 12 5.5M9.4 7.2 10 3h4l.6 4.2M9.4 16.8 10 21h4l.6-4.2M12 9.6V12l1.6 1')]);
  static const headphones = LGlyph('headphones', [_S('M4 14v-2a8 8 0 0 1 16 0v2M4 14h3v6H4zM17 14h3v6h-3z')], proto: true);
  static const coffee = LGlyph('coffee',
      [_S('M5 8h12v6a6 6 0 0 1-12 0zM17 9h1.5a2.5 2.5 0 0 1 0 5H17M8 3c0 1.5 1 1.5 1 3M12 3c0 1.5 1 1.5 1 3')],
      proto: true);

  /// 药剂（伙伴效果）。
  static const potion = LGlyph('potion', [_S('M9 3h6M10 3v5.5L5.2 17a2.6 2.6 0 0 0 2.3 4h9a2.6 2.6 0 0 0 2.3-4L14 8.5V3M7 15h10')]);

  // ── 影音与相机 ────────────────────────────────────────────
  static const play = LGlyph('play', [_F('M8 5v14l11-7z')], proto: true);
  static const pause = LGlyph('pause', [_F('M6.5 5h3.5v14H6.5zM14 5h3.5v14H14z')], proto: true);
  static const stop = LGlyph('stop', [_F('M6.5 6.5h11v11h-11z')], proto: true);
  static const playCircle = LGlyph('playCircle', [_S('O12 12 8.5'), _F('M10.2 8.6v6.8l5.2-3.4z')]);
  static const stopCircle = LGlyph('stopCircle', [_S('O12 12 8.5'), _F('M9.3 9.3h5.4v5.4H9.3z')]);

  /// 回放 / 视频。
  static const film = LGlyph('film', [_S('M4 5h16v14H4zM10 9v6l5-3z')], proto: true);
  static const videocam = LGlyph('videocam', [_S('M3 7h12v10H3zM15 10.5 21 7v10l-6-3.5')]);
  static const camera = LGlyph('camera', [_S('M4 8h3l2-3h6l2 3h3v11H4zO12 13 3.5')], proto: true);
  static const image = LGlyph('image', [_S('M4 4h16v16H4zM4 15l5-5 4 4 3-3 4 4')], proto: true);
  static const images = LGlyph('images', [_S('M7.5 7.5h13v13h-13zM7.5 16.5l4-4 3.5 3.5 2.5-2.5 3 3M3.5 16.5v-13h13')], proto: true);

  /// 朋友圈（原型分享面板）。
  static const moments = LGlyph('moments', [_S('O12 12 9O12 12 4')], proto: true);
  static const flashlight = LGlyph('flashlight', [_S('M8 3h8v4l-2 3v11h-4V10L8 7zM8 7h8M12 13v2')]);
  static const scan = LGlyph('scan', [_S('M4 8.5V4h4.5M15.5 4H20v4.5M20 15.5V20h-4.5M8.5 20H4v-4.5M7 12h10')]);
  static const volume = LGlyph('volume', [_S('M4 9.5h3.5L12 5v14l-4.5-4.5H4zM15.5 9.2a4 4 0 0 1 0 5.6M18.2 6.5a7.8 7.8 0 0 1 0 11')]);
  static const volumeOff = LGlyph('volumeOff', [_S('M4 9.5h3.5L12 5v14l-4.5-4.5H4zM16 9.5l5 5M21 9.5l-5 5')]);

  // ── 能量与游戏 ────────────────────────────────────────────
  static const bolt = LGlyph('bolt', [_F('M13 2 4 14h7l-1 8 9-12h-7z')], proto: true);
  static const flame = LGlyph('flame', [_S('M12 3c1 4 5 5 5 10a5 5 0 0 1-10 0c0-3 2-4 2-7 2 1 3 3 3 5')], proto: true);
  static const shield = LGlyph('shield', [_S('M12 3 4 6v6c0 4.5 3.4 8 8 9 4.6-1 8-4.5 8-9V6z')], proto: true);
  static const shieldCheck = LGlyph('shieldCheck', [_S('M12 3 4 6v6c0 4.5 3.4 8 8 9 4.6-1 8-4.5 8-9V6zM8.5 12l2.5 2.5 4.5-5')], proto: true);
  static const shieldAlert = LGlyph('shieldAlert', [_S('M12 3 4 6v6c0 4.5 3.4 8 8 9 4.6-1 8-4.5 8-9V6zM12 8v4.5'), _F('O12 15.6 1.1')], proto: true);

  /// 夜间守护（盾里一弯月亮）。
  static const shieldMoon = LGlyph('shieldMoon', [_S('M12 3 4 6v6c0 4.5 3.4 8 8 9 4.6-1 8-4.5 8-9V6zM13.6 8.2a4 4 0 1 0 2.2 6.6 3.3 3.3 0 0 1-2.2-6.6z')]);
  static const flag = LGlyph('flag', [_S('M5 21V4h11l-2 4 2 4H5')], proto: true);
  static const flagFilled = LGlyph('flagFilled', [_S('M5 21V4'), _F('M5 4h11l-2 4 2 4H5z')], proto: true);
  static const trophy = LGlyph('trophy',
      [_S('M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0zM7 6H4v2a3 3 0 0 0 3 3M17 6h3v2a3 3 0 0 1-3 3')], proto: true);
  static const medal = LGlyph('medal', [_S('O12 15 5.5M8.5 10.5 6 3h4l2 5 2-5h4l-2.5 7.5')], proto: true);
  static const crown = LGlyph('crown', [_S('M3 8l4.5 4L12 5l4.5 7L21 8l-2 11H5z')], proto: true);

  /// 宝箱。
  static const chest = LGlyph('chest', [_S('M4 10h16v10H4zM4 10l2-5h12l2 5M12 10v4')], proto: true);
  static const gift = LGlyph('gift',
      [_S('M20 12v9H4v-9M2.5 7h19v5h-19zM12 21V7M12 7C10 3 7 3 7 5s5 2 5 2M12 7c2-4 5-4 5-2s-5 2-5 2')], proto: true);

  /// 券（两侧缺口 + 撕线）。
  static const ticket = LGlyph('ticket', [_S('M3 6.5h18V10a2 2 0 0 0 0 4v3.5H3V14a2 2 0 0 0 0-4zM14.5 6.5v1.5M14.5 11.2v1.6M14.5 16v1.5')]);
  static const tag = LGlyph('tag', [_S('M4 4h7.5l8.5 8.5-7.5 7.5L4 11.5zO8.5 8.5 1.3')]);

  /// 次卡 / 套票（一叠卡片）。
  static const cards = LGlyph('cards', [_S('M4 9h16v11H4zM6 6h12M8.5 3h7')]);
  static const trendUp = LGlyph('trendUp', [_S('M3 17l6-6 4 4 8-8M15 7h6v6')]);
  static const rules = LGlyph('rules', [_S('M11 6.5h9M11 12h9M11 17.5h9M3.5 6.5l1.6 1.6L8 5M3.5 12l1.6 1.6L8 10.5M4 17.5h3')]);
  static const lock = LGlyph('lock', [_S('M5 11h14v10H5zM8 11V8a4 4 0 0 1 8 0v3')], proto: true);
  static const unlock = LGlyph('unlock', [_S('M5 11h14v10H5zM8 11V8a4 4 0 0 1 7.7-1.6')], proto: true);

  /// 认证徽章。
  static const verified = LGlyph('verified', [
    _S('M12 2.7l2.9 2.3 3.7.4.4 3.7 2.3 2.9-2.3 2.9-.4 3.7-3.7.4-2.9 2.3-2.9-2.3-3.7-.4-.4-3.7L2.7 12 5 9.1l.4-3.7 3.7-.4z'
        'M8.6 12.2l2.3 2.3 4.5-4.8'),
  ]);

  // ── 人与社交 ──────────────────────────────────────────────
  static const user = LGlyph('user', [_S('O12 8 4M4 21c1-4 4.2-6.5 8-6.5s7 2.5 8 6.5')], proto: true);
  static const users = LGlyph('users', [
    _S('O9 8 3.5M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5M16 4.5a3.5 3.5 0 0 1 0 7M18 14.8c1.9.8 3.1 2.6 3.5 5.2'),
  ], proto: true);
  static const userPlus = LGlyph('userPlus', [_S('O9 8 3M3 20c1-3.5 3.4-5 6-5s5 1.5 6 5M18 8v6M15 11h6')], proto: true);
  static const userCheck = LGlyph('userCheck', [_S('O9 8 3M3 20c1-3.5 3.4-5 6-5s5 1.5 6 5M15 11l2 2 4-4')], proto: true);
  static const chat = LGlyph('chat', [_S('M4 5h16v11H9l-5 4z')], proto: true);
  static const chats = LGlyph('chats', [_S('M3 4h13v9H8l-5 3.5zM19.5 8H21v12.5L17 17H9v-1.5')], proto: true);
  static const reply = LGlyph('reply', [_S('M10 5 4 11l6 6M4 11h9a7 7 0 0 1 7 7v1')]);

  /// 分享（原型动态卡片的纸飞机）。
  static const share = LGlyph('share', [_S('M21 3 3 10l7 3 3 7zM21 3 10 13')], proto: true);

  /// 用系统分享发出去（向上的箭头出盒子）。
  static const shareOut = LGlyph('shareOut', [_S('M12 3.5v11M7.5 8 12 3.5 16.5 8M5 12v8h14v-8')]);
  static const heart = LGlyph('heart', [_S('M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z')], proto: true);
  static const heartFilled =
      LGlyph('heartFilled', [_F('M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z')], proto: true);
  static const bookmark = LGlyph('bookmark', [_S('M6 3h12v18l-6-4-6 4z')], proto: true);
  static const bookmarkFilled = LGlyph('bookmarkFilled', [_F('M6 3h12v18l-6-4-6 4z')], proto: true);
  static const bell = LGlyph('bell', [_S('M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15zM10 21h4')], proto: true);
  static const bellRing = LGlyph('bellRing', [_S('M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15zM10 21h4M2.8 9.5a9 9 0 0 1 2.7-5M21.2 9.5a9 9 0 0 0-2.7-5')], proto: true);
  static const bellOff = LGlyph('bellOff', [
    _S('M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15zM10 21h4'),
    _X('M4 4l16 16', 2.4),
    _S('M4 4l16 16'),
  ], proto: true);
  static const megaphone = LGlyph('megaphone', [_S('M4 9.5v5h3l8.5 5V4.5L7 9.5zM18.5 9.5a3.5 3.5 0 0 1 0 5M7 14.5 8.5 20H11l-1-5')]);
  static const mail = LGlyph('mail', [_S('M3 6h18v12H3zM3.5 6.5 12 13l8.5-6.5')]);

  // ── 编辑与文件 ────────────────────────────────────────────
  static const pencil = LGlyph('pencil', [_S('M4 20l1-4.5L15.5 5a2.1 2.1 0 0 1 3 3L8 18.5zM13.5 7l3 3')]);
  static const editNote = LGlyph('editNote', [_S('M4 6h11M4 11h7M4 16h4M11.5 20l.7-3.2 6.6-6.6a1.8 1.8 0 0 1 2.5 2.5l-6.6 6.6z')]);
  static const trash = LGlyph('trash', [_S('M4 7h16M9.5 7V4h5v3M6 7l1 14h10l1-14M10 11v6M14 11v6')]);
  static const copy = LGlyph('copy', [_S('M9 9h11v11H9zM5.5 15H4V4h11v1.5')]);

  /// 图鉴（底栏，原型同款叠卡）。
  static const codex = LGlyph('codex', [_S('M8 3h11v15H8zM5 6v15h11')], proto: true);
  static const link = LGlyph('link',
      [_S('M10 14a4 4 0 0 0 6 0l3-3a4 4 0 0 0-6-6l-1 1M14 10a4 4 0 0 0-6 0l-3 3a4 4 0 0 0 6 6l1-1')], proto: true);
  static const download = LGlyph('download', [_S('M12 4v12M7 11l5 5 5-5M5 20h14')], proto: true);
  static const upload =
      LGlyph('upload', [_S('M7.5 18.5h-1a4.5 4.5 0 0 1-.5-9 6 6 0 0 1 11.6 1.6 3.8 3.8 0 0 1-.1 7.4h-1M12 12.5v8M9 15.5l3-3 3 3')]);
  static const cloudOff = LGlyph('cloudOff', [
    _S('M6.5 18.5a4.5 4.5 0 0 1-.5-9 6 6 0 0 1 11.6 1.6 3.8 3.8 0 0 1-.1 7.4z'),
    _X('M4 4l16 16', 2.4),
    _S('M4 4l16 16'),
  ]);
  static const receipt = LGlyph('receipt', [_S('M6 3h12v18l-2-1.5-2 1.5-2-1.5-2 1.5-2-1.5L6 21zM9 8h6M9 12h6M9 16h3')]);
  static const wallet = LGlyph('wallet', [_S('M3.5 7.5h17v12h-17zM3.5 7.5 15 4v3.5M15 11.5h5.5v4H15z')]);
  static const doc = LGlyph('doc', [_S('M6 3h9l4 4v14H6zM9 12h7M9 16h5')], proto: true);

  /// Apple 标志（只用于「通过 Apple 登录」）。
  static const apple = LGlyph('apple', [
    _F('M16.4 12.7c0-2.2 1.8-3.3 1.9-3.3-1-1.5-2.6-1.7-3.2-1.7-1.4-.1-2.7.8-3.4.8-.7 0-1.8-.8-2.9-.8-1.5 0-2.9.9-3.7 2.2'
        '-1.6 2.7-.4 6.7 1.1 8.9.8 1.1 1.6 2.3 2.8 2.2 1.1 0 1.5-.7 2.9-.7 1.3 0 1.7.7 2.9.7 1.2 0 2-1.1 2.7-2.2.9-1.2 1.2-2.4 1.2-2.5'
        ' 0 0-2.3-.9-2.3-3.6zM14.2 6.1c.6-.8 1-1.8.9-2.8-.9 0-2 .6-2.6 1.3-.6.6-1.1 1.7-.9 2.7 1 .1 2-.5 2.6-1.2z'),
  ]);

  // ── 圈圈 ──────────────────────────────────────────────────
  /// 「圈圈」助手的单色标志：品牌双环 oo，右边的实心圈长出一张小脸。
  /// 彩色版见 [QuanMark]。
  static const quan = LGlyph('quan', [
    _F('O15.6 12 7.4'),
    _X('O6.6 12 5.2', 2.4),
    _XF('O16.4 10.6 1.2O19.8 10.6 1.2'),
    _X('M15.9 14q2.2 2 4.4 0', -0.3),
    _S('O6.6 12 5.2'),
  ], proto: true);

  /// 全部图标（图标总览用），按上面的顺序。
  static const all = <LGlyph>[
    back, chevronRight, chevronDown, chevronUp, arrowRight, send, close, plus, minus, plusCircle, minusCircle, //
    moreH, moreV, check, checkCircle, checkCircleFilled, ring, dot, search, sliders, info, alert, block, //
    map, plot, pin, pinFilled, pinCheck, pinOff, locate, navigate, compass, route, relay, layers, mountain, //
    ruler, signal, loopRoute, loops, refresh, replay, history, clock, timer, hourglass, calendar, calendarCheck, //
    run, walk, bike, tennis, dumbbell, yoga, rope, venue, store, gamepad, scribble, buddy, castle, egg, watch, //
    headphones, coffee, potion, play, pause, stop, playCircle, stopCircle, film, videocam, camera, image, images, //
    moments, flashlight, scan, volume, volumeOff, bolt, flame, shield, shieldCheck, shieldAlert, shieldMoon, flag, //
    flagFilled, trophy, medal, crown, chest, gift, ticket, tag, cards, trendUp, rules, lock, unlock, verified, //
    user, users, userPlus, userCheck, chat, chats, reply, share, shareOut, heart, heartFilled, bookmark, //
    bookmarkFilled, bell, bellRing, bellOff, megaphone, mail, pencil, editNote, trash, copy, codex, link, //
    download, upload, cloudOff, receipt, wallet, doc, apple, quan,
  ];
}

/// 解析好的路径缓存（同一段路径只解析一次）。
final Map<String, Path> _pathCache = {};

final RegExp _circle = RegExp(r'O\s*(-?[\d.]+)[\s,]+(-?[\d.]+)[\s,]+([\d.]+)');

String _num(double v) => v.toStringAsFixed(3);

Path _path(String d) => _pathCache.putIfAbsent(d, () {
      final svg = d.replaceAllMapped(_circle, (m) {
        final cx = double.parse(m[1]!), cy = double.parse(m[2]!), r = double.parse(m[3]!);
        return 'M${_num(cx - r)} ${_num(cy)}a${_num(r)} ${_num(r)} 0 1 0 ${_num(2 * r)} 0'
            'a${_num(r)} ${_num(r)} 0 1 0 ${_num(-2 * r)} 0z';
      });
      final p = Path();
      try {
        writeSvgPathDataToPath(svg, _PathProxy(p));
      } on StateError catch (e) {
        throw ArgumentError.value(d, 'LGlyph path', e.message);
      }
      return p;
    });

class _PathProxy implements PathProxy {
  _PathProxy(this.p);
  final Path p;
  @override
  void moveTo(double x, double y) => p.moveTo(x, y);
  @override
  void lineTo(double x, double y) => p.lineTo(x, y);
  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) => p.cubicTo(x1, y1, x2, y2, x3, y3);
  @override
  void close() => p.close();
}

/// 画一个 [LGlyph]：可直接替换 [Icon]。
class LIcon extends StatelessWidget {
  const LIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel, this.shadows});

  final LGlyph? icon;

  /// 不给时取 [IconTheme] 的 size（默认 24）。
  final double? size;

  /// 不给时取 [IconTheme] 的 color（并乘上它的 opacity）。
  final Color? color;
  final String? semanticLabel;
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    var c = color ?? theme.color ?? const Color(0xFF000000);
    final o = theme.opacity;
    if (color == null && o != null && o != 1.0) c = c.withValues(alpha: c.a * o);
    final g = icon;
    Widget child = SizedBox(
      width: s,
      height: s,
      // 和 Icon 一样：外面被撑大（比如放进没设 alignment 的 Container）时图标仍按 size 画在中间
      child: g == null ? null : CustomPaint(painter: _GlyphPainter(g, c, shadows ?? theme.shadows, s)),
    );
    return Semantics(label: semanticLabel, child: ExcludeSemantics(child: child));
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color, this.shadows, this.iconSize);
  final LGlyph glyph;
  final Color color;
  final List<Shadow>? shadows;
  final double iconSize;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(iconSize, size.shortestSide);
    if (side <= 0) return;
    final k = side / 24;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(k);
    final sw = LGlyph.strokeUnits(side);
    for (final sh in shadows ?? const <Shadow>[]) {
      canvas.save();
      canvas.translate(sh.offset.dx / k, sh.offset.dy / k);
      _draw(canvas, sw, sh.color, MaskFilter.blur(BlurStyle.normal, sh.blurSigma / k));
      canvas.restore();
    }
    _draw(canvas, sw, color, null);
    canvas.restore();
  }

  void _draw(Canvas canvas, double sw, Color c, MaskFilter? blur) {
    final hasCut = glyph.parts.any((p) => p.cut);
    final layered = hasCut || c.a < 1;
    final ink = layered ? c.withValues(alpha: 1) : c;
    if (layered) canvas.saveLayer(const Rect.fromLTWH(-4, -4, 32, 32), Paint()..color = Color.fromRGBO(0, 0, 0, c.a));
    for (final part in glyph.parts) {
      final path = _path(part.d);
      final paint = Paint()
        ..color = ink
        ..maskFilter = blur
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (part.cut) paint.blendMode = BlendMode.dstOut;
      if (part.fill) {
        canvas.drawPath(path, paint..style = PaintingStyle.fill);
        // 填充的边缘再描一圈细线，尖角变得圆润，和描边图标的圆角一致
        canvas.drawPath(path, paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = part.cut ? 0.5 : 0.9);
      } else {
        canvas.drawPath(path, paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.1, sw + part.extra));
      }
    }
    if (layered) canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color || old.shadows != shadows || old.iconSize != iconSize;
}

/// 「圈圈」AI 助手的形象：品牌双环 oo（左边空心圈是路线，右边荧光绿实心圈是圈下的地），
/// 实心圈上一双豆豆眼和一个笑。尺寸不小于 28 时，空心圈顶上带品牌的紫色小圆点（跑者）。
///
/// 深色底用默认配色；放在浅色或彩色底上时把 [ringColor] 设成墨黑。
/// 要整枚单色（比如放在荧光绿底上），用 `LIcon(LIcons.quan)`。
class QuanMark extends StatelessWidget {
  const QuanMark({
    super.key,
    this.size = 24,
    this.ringColor = LL.text,
    this.discColor = LL.lime,
    this.faceColor = LL.ink,
    this.runner,
    this.semanticLabel,
  });

  final double size;
  final Color ringColor, discColor, faceColor;

  /// 空心圈顶上的紫点；不给时尺寸 ≥ 28 才画（品牌规范：小于 24 px 去掉紫点）。
  final bool? runner;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        child: ExcludeSemantics(
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _QuanPainter(ringColor, discColor, faceColor, runner ?? size >= 28, size)),
          ),
        ),
      );
}

class _QuanPainter extends CustomPainter {
  _QuanPainter(this.ring, this.disc, this.face, this.runner, this.markSize);
  final Color ring, disc, face;
  final bool runner;
  final double markSize;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(markSize, size.shortestSide);
    if (side <= 0) return;
    final k = side / 24;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);
    canvas.scale(k);
    final sw = LGlyph.strokeUnits(side) + 0.4; // 品牌标志的圈比普通线条粗
    const ringC = Offset(6.6, 12), ringR = 5.2;
    canvas.saveLayer(const Rect.fromLTWH(-4, -4, 32, 32), Paint());
    // 实心圈
    canvas.drawCircle(const Offset(15.6, 12), 7.4, Paint()..color = disc);
    // 空心圈压在实心圈上，中间留一道缝
    canvas.drawCircle(ringC, ringR, Paint()
      ..blendMode = BlendMode.dstOut
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw + 2.4);
    final ringPaint = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw;
    canvas.drawCircle(ringC, ringR, ringPaint);
    if (runner) {
      // 紫点所在处把圈断开
      canvas.drawCircle(Offset(ringC.dx, ringC.dy - ringR), 2.3, Paint()..blendMode = BlendMode.dstOut);
      canvas.drawCircle(Offset(ringC.dx, ringC.dy - ringR), 1.5, Paint()..color = LL.lavender);
    }
    // 脸
    final facePaint = Paint()..color = face;
    canvas.drawCircle(const Offset(16.4, 10.6), 1.2, facePaint);
    canvas.drawCircle(const Offset(19.8, 10.6), 1.2, facePaint);
    canvas.drawPath(
        _path('M15.9 14q2.2 2 4.4 0'),
        Paint()
          ..color = face
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = sw - 0.4);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QuanPainter old) => old.ring != ring || old.disc != disc || old.face != face || old.runner != runner || old.markSize != markSize;
}
