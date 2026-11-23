import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import 'card_art.dart' show hasArt;
import 'l_icons.dart';
import 'nav_bar_cover.dart';
import 'running_gecko.dart';

/// Scaffold with the floating rounded bottom bar: 领地 / 图鉴 / 开始 / 社区 / 我的.
class NavShell extends ConsumerWidget {
  const NavShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const double barHeight = 76;

  /// Bottom padding pages should leave for the floating bar.
  static double bottomInset(BuildContext context) => barHeight + 28 + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final escort = ref.watch(codexProvider).value?.companions.where((c) => c.escort).firstOrNull;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final cover = ref.watch(navBarCoverProvider);
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: shell),
        Positioned(
          left: 12,
          right: 12,
          bottom: 12 + bottom,
          // 标签页里弹出底部面板（领地详情、宝箱等）时，底栏滑下去收起，不挡住面板
          child: ListenableBuilder(
            listenable: cover,
            builder: (context, child) => IgnorePointer(
              ignoring: cover.covered,
              child: AnimatedSlide(
                offset: cover.covered ? const Offset(0, 1.4) : Offset.zero,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: cover.covered ? 0 : 1,
                  duration: const Duration(milliseconds: 180),
                  child: child,
                ),
              ),
            ),
            child: _Bar(
              index: shell.currentIndex,
              onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
              centerArt: escort?.key ?? 'gecko',
            ),
          ),
        ),
      ]),
    );
  }
}

/// 底栏。选中的普通标签（领地 / 图鉴 / 社区 / 我的）是一个浮在上沿的荧光绿圆球，
/// 底栏在它下面凹进去；切换时圆球从凹口弹起、沿弧线飞到新位置落下，
/// 旧凹口合上、新凹口带回弹地张开（液态气泡效果）。切到中间「开始」时圆球缩进按钮里。
class _Bar extends StatefulWidget {
  const _Bar({required this.index, required this.onTap, required this.centerArt});
  final int index;
  final ValueChanged<int> onTap;
  final String centerArt;

  @override
  State<_Bar> createState() => _BarState();
}

class _BarState extends State<_Bar> with SingleTickerProviderStateMixin {
  static const _icons = [LIcons.map, LIcons.codex, LIcons.play, LIcons.users, LIcons.user];
  static const _labels = ['领地', '图鉴', '开始', '社区', '我的'];
  static const button = 84.0; // 中间「开始」按钮直径（含外圈）
  static const ball = 44.0; // 选中圆球直径
  static const notchDepth = 38.0; // 凹口深度（圆球一半落在凹口里，四周留一圈缝）
  static const pad = 22.0; // 两端图标离底栏边缘的距离（给圆角让出位置）

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700), value: 1);
  late int _from = widget.index, _to = widget.index;

  @override
  void didUpdateWidget(_Bar old) {
    super.didUpdateWidget(old);
    if (widget.index == _to) return;
    _from = _to;
    _to = widget.index;
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: NavShell.barHeight + 22,
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        final itemW = (w - 2 * pad - button - 12) / 4;
        double x(int i) => switch (i) {
              0 => pad + itemW / 2,
              1 => pad + itemW * 1.5,
              2 => w / 2,
              3 => w / 2 + (button + 12) / 2 + itemW / 2,
              _ => w - pad - itemW / 2,
            };
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            final moving = _from != _to && t < 1;
            // 凹口：旧的在前 30% 合上，新的在后 40% 带回弹张开
            final notches = <(double, double)>[
              if (moving && _from != 2) (x(_from), notchDepth * (1 - Curves.easeIn.transform(_seg(t, 0, 0.3)))),
              if (_to != 2) (x(_to), notchDepth * (moving ? const ElasticOutCurve(0.45).transform(_seg(t, 0.6, 1)) : 1).clamp(0.0, 2.0)),
            ];
            // 圆球：水平按缓动移动，竖直走一条抛物线（经过中间按钮时抛得更高）
            final move = Curves.easeInOutCubic.transform(_seg(t, 0.05, 0.85));
            final crossesCenter = (_from - 2) * (_to - 2) < 0;
            final lift = moving ? (crossesCenter ? 70.0 : 44.0) * math.sin(math.pi * _seg(t, 0, 0.9)) : 0.0;
            final ballX = moving ? x(_from) + (x(_to) - x(_from)) * move : x(_to);
            var scale = 1.0;
            if (moving && _from == 2) scale = Curves.easeOutBack.transform(_seg(t, 0, 0.3));
            if (_to == 2) scale = moving ? 1 - Curves.easeIn.transform(_seg(t, 0.6, 0.9)) : 0;
            // 球里的图标：先淡出旧的，落下前淡入新的
            final showTo = !moving || t > 0.7;
            final iconOpacity = !moving ? 1.0 : (t < 0.2 ? 1 - _seg(t, 0, 0.2) : _seg(t, 0.7, 0.9));
            double itemOpacity(int i) {
              if (i == _to) return moving ? 1 - _seg(t, 0.55, 0.7) : 0;
              if (i == _from && moving) return _seg(t, 0.05, 0.3);
              return 1;
            }

            Widget item(int i) => Expanded(
                  child: Semantics(
                    button: true,
                    selected: widget.index == i,
                    label: _labels[i],
                    child: InkResponse(
                      onTap: () => widget.onTap(i),
                      child: Center(
                        child: Opacity(
                          opacity: itemOpacity(i),
                          child: LIcon(_icons[i], color: LL.text3, size: 28),
                        ),
                      ),
                    ),
                  ),
                );

            const barTop = 22.0;
            return Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
              // 底栏：中间向上鼓起托住「开始」按钮，选中项位置凹进去
              SizedBox(
                height: NavShell.barHeight,
                width: double.infinity,
                child: CustomPaint(
                  painter: _BarPainter(hump: button / 2 + 10, notches: notches),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: pad),
                    child: Row(children: [item(0), item(1), const SizedBox(width: button + 12), item(3), item(4)]),
                  ),
                ),
              ),
              Positioned(
                bottom: NavShell.barHeight / 2 - button / 2 + 6,
                child: Semantics(
                  button: true,
                  selected: widget.index == 2,
                  label: '开始',
                  child: GestureDetector(
                    onTap: () => widget.onTap(2),
                    child: _StartButton(size: button, selected: widget.index == 2, art: widget.centerArt),
                  ),
                ),
              ),
              // 选中圆球（只是视觉，点击落到下面的标签上）
              if (scale > 0.01)
                Positioned(
                  left: ballX - ball / 2,
                  top: barTop + 8 - ball / 2 - lift,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          width: ball,
                          height: ball,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFFEAFA94), LL.lime],
                            ),
                            boxShadow: [BoxShadow(color: LL.lime.withValues(alpha: 0.3), blurRadius: 12)],
                          ),
                          child: Opacity(
                            opacity: iconOpacity,
                            child: LIcon(_icons[showTo ? _to : _from], color: LL.ink, size: 24),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]);
          },
        );
      }),
    );
  }
}

/// 中间的「开始」按钮（同原型 Main）：外圈虚线 14 秒转一圈，里面的小壁虎原地奔跑
/// （腿 0.64 秒摆一个来回）。出战伙伴不是壁虎时，显示它的形象并按同样的步频颠动。
/// 系统开启「减弱动态效果」时静止。
class _StartButton extends StatefulWidget {
  const _StartButton({required this.size, required this.selected, required this.art});
  final double size;
  final bool selected;
  final String art;

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton> with TickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(seconds: 14));
  late final AnimationController _gait = AnimationController(vsync: this, duration: const Duration(milliseconds: 640));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final c in [_ring, _gait]) {
      if (MediaQuery.disableAnimationsOf(context)) {
        c.stop();
      } else if (!c.isAnimating) {
        c.repeat();
      }
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    _gait.dispose();
    super.dispose();
  }

  Widget _figure() {
    final art = widget.art;
    if (art == 'gecko' || !hasArt(art)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 6, 6),
        child: AnimatedBuilder(
          animation: _gait,
          builder: (_, _) => CustomPaint(painter: RunningGeckoPainter(_gait.value), size: Size.infinite),
        ),
      );
    }
    // 其他伙伴：按跑步的步频颠动、身体前倾
    return ClipOval(
      child: AnimatedBuilder(
        animation: _gait,
        builder: (_, child) => Transform.translate(
          offset: Offset(-2, -5 - 2.5 * RunningGeckoPainter.tri(_gait.value * 2)),
          child: Transform.rotate(angle: -0.08, child: child),
        ),
        child: Transform.scale(
          scale: 1.22,
          child: SvgPicture.asset('assets/art/${art}_fig.svg', fit: BoxFit.contain),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(fit: StackFit.expand, children: [
        // 外圈虚线（薰衣紫），缓慢旋转
        RotationTransition(
          turns: _ring,
          child: CustomPaint(painter: _DashedRingPainter(color: LL.lavender.withValues(alpha: 0.8))),
        ),
        Padding(
          padding: const EdgeInsets.all(7),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: LL.lavender,
              // 选中「开始」时外环加粗
              border: Border.all(color: LL.lime, width: widget.selected ? 3.5 : 2.5),
              boxShadow: [BoxShadow(color: LL.lavender.withValues(alpha: 0.45), blurRadius: 18)],
            ),
            child: _figure(),
          ),
        ),
      ]),
    );
  }
}

/// 底栏背景：圆角矩形，中间顶部向上鼓起一个平滑的弧，选中项位置向下凹一个碗形缺口。
/// 上沿按从左到右依次画出凹口和鼓包（不用路径布尔运算，避免边缘重合时算错）。
class _BarPainter extends CustomPainter {
  _BarPainter({required this.hump, this.notches = const []});
  final double hump; // 鼓起部分的半宽
  final List<(double, double)> notches; // 凹口：(中心 x, 深度)

  static const radius = 28.0; // 底栏圆角
  static const shoulder = 36.0; // 凹口单侧宽度（靠近圆角、鼓包或另一个凹口时自动收窄）
  static const rise = 14.0; // 鼓起高度

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, r = radius, cx = w / 2;
    final humpL = cx - hump - 4, humpR = cx + hump + 4; // 鼓包两端
    // 每个凹口两侧的宽度：不进圆角、不进鼓包、和相邻凹口在中点分开
    final list = [for (final n in notches) if (n.$2 >= 0.5) n]..sort((a, b) => a.$1.compareTo(b.$1));
    final sides = <(double, double)>[];
    for (var i = 0; i < list.length; i++) {
      final x = list[i].$1;
      var l = math.min(shoulder, x < cx ? x - r - 2 : x - humpR);
      var rr = math.min(shoulder, x < cx ? humpL - x : w - r - 2 - x);
      if (i > 0) l = math.min(l, (x - list[i - 1].$1) / 2);
      if (i < list.length - 1) rr = math.min(rr, (list[i + 1].$1 - x) / 2);
      sides.add((l, rr));
    }
    final path = Path()..moveTo(r, 0);
    void notch(int i) {
      final (x, d) = list[i];
      final (l, rr) = sides[i];
      if (l < 4 || rr < 4) return;
      path
        ..lineTo(x - l, 0)
        ..cubicTo(x - l * 0.45, 0, x - l * 0.6, d, x, d)
        ..cubicTo(x + rr * 0.6, d, x + rr * 0.45, 0, x + rr, 0);
    }

    for (var i = 0; i < list.length; i++) {
      if (list[i].$1 < cx) notch(i);
    }
    path
      ..lineTo(humpL, 0)
      ..cubicTo(cx - hump + 12, 0, cx - hump + 8, -rise, cx, -rise)
      ..cubicTo(cx + hump - 8, -rise, cx + hump - 12, 0, humpR, 0);
    for (var i = 0; i < list.length; i++) {
      if (list[i].$1 > cx) notch(i);
    }
    path
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: const Radius.circular(radius))
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: const Radius.circular(radius))
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: const Radius.circular(radius))
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: const Radius.circular(radius))
      ..close();
    canvas.drawShadow(path, const Color(0xFF000000), 12, false);
    canvas.drawPath(path, Paint()..color = const Color(0xF21B1B20));
    canvas.drawPath(path, Paint()
      ..color = const Color(0xFF3A3A42) // 描边略亮一点，凹口轮廓在深色背景上也看得出
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(_BarPainter old) => true;
}

/// 「开始」按钮外圈的虚线圆。
class _DashedRingPainter extends CustomPainter {
  _DashedRingPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final rect = Offset.zero & size;
    const dashes = 28;
    const sweep = 2 * 3.141592653589793 / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect.deflate(1.5), i * sweep, sweep * 0.35, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}
