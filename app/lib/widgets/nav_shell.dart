import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/audio.dart';
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
              onTap: (i) {
                final audio = ref.read(audioProvider);
                if (i == 2) {
                  // 「开始」：起跑的「咚」；已经在开始页时，按钮里的伙伴叫一声
                  audio.play(shell.currentIndex == 2 ? Sounds.petTap(escort?.key ?? 'gecko') : Sounds.startPress);
                  audio.haptic(HapticKind.light);
                } else if (i != shell.currentIndex) {
                  audio.play(Sounds.uiTab);
                }
                shell.goBranch(i, initialLocation: i == shell.currentIndex);
              },
              centerArt: escort?.key ?? 'gecko',
            ),
          ),
        ),
      ]),
    );
  }
}

/// 底栏。选中的普通标签（领地 / 图鉴 / 社区 / 我的）在栏内有一块荧光绿圆角高亮，
/// 图标变成深色；切换时高亮在栏内滑到新位置（滑动途中略微拉长），不跳出底栏。
/// 选中中间「开始」时高亮收起，由「开始」按钮自己表示选中。点按时那一格有一下变色反馈。
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
  static const pad = 10.0; // 两端标签离底栏边缘的距离
  static const pillH = 52.0; // 高亮块高度

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380), value: 1);
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
        final pillW = itemW - 6;
        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_c.value);
            final moving = _from != _to && _c.value < 1;
            // 高亮位置与宽度：滑动途中拉长一点（像被拖过去），到位后回到原宽
            final cx = moving ? x(_from) + (x(_to) - x(_from)) * t : x(_to);
            final stretch = moving && _from != 2 && _to != 2 && (_from - 2) * (_to - 2) > 0 ? math.sin(math.pi * _c.value) * math.min(28.0, (x(_to) - x(_from)).abs() * 0.18) : 0.0;
            // 切到 / 离开中间「开始」：高亮在原位收起 / 在新位置展开；
            // 跨过中间按钮的切换（左右两侧之间）：前半段在原位收起、后半段在新位置展开，不从按钮底下滑过
            var scale = 1.0;
            var pillX = cx;
            final crosses = (_from - 2) * (_to - 2) < 0;
            if (_to == 2) {
              scale = moving ? 1 - t : 0;
              pillX = moving ? x(_from) : x(_to);
            } else if (moving && _from == 2) {
              scale = t;
              pillX = x(_to);
            } else if (moving && crosses) {
              final v = _c.value;
              scale = v < 0.5 ? 1 - Curves.easeIn.transform(v * 2) : Curves.easeOutBack.transform((v - 0.5) * 2);
              pillX = v < 0.5 ? x(_from) : x(_to);
            }

            Widget item(int i) {
              final sel = widget.index == i;
              return Expanded(
                child: Semantics(
                  button: true,
                  selected: sel,
                  label: _labels[i],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: (NavShell.barHeight - pillH) / 2),
                    child: Material(
                      type: MaterialType.transparency,
                      child: InkWell(
                        onTap: () => widget.onTap(i),
                        borderRadius: BorderRadius.circular(18),
                        splashColor: LL.lime.withValues(alpha: 0.28),
                        highlightColor: LL.lime.withValues(alpha: 0.16),
                        child: Center(
                          child: TweenAnimationBuilder<Color?>(
                            tween: ColorTween(end: sel ? LL.ink : LL.text3),
                            duration: const Duration(milliseconds: 220),
                            builder: (_, c, _) => LIcon(_icons[i], color: c, size: 26),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
              // 底栏：中间向上鼓起托住「开始」按钮
              SizedBox(
                height: NavShell.barHeight,
                width: double.infinity,
                child: CustomPaint(
                  painter: _BarPainter(hump: button / 2 + 10),
                  child: Stack(children: [
                    // 选中高亮（在栏内，不越出底栏）
                    if (scale > 0.01)
                      Positioned(
                        left: pillX - (pillW + stretch) / 2,
                        top: (NavShell.barHeight - pillH) / 2,
                        width: pillW + stretch,
                        height: pillH,
                        child: IgnorePointer(
                          child: Transform.scale(
                            scale: scale,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: LL.lime,
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [BoxShadow(color: LL.lime.withValues(alpha: 0.22), blurRadius: 10)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: pad),
                      child: Row(children: [item(0), item(1), const SizedBox(width: button + 12), item(3), item(4)]),
                    ),
                  ]),
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

/// 底栏背景：圆角胶囊，中间顶部向上鼓起一个平滑的弧，托住「开始」按钮。
class _BarPainter extends CustomPainter {
  _BarPainter({required this.hump});
  final double hump; // 鼓起部分的半宽

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, r = h / 2, cx = w / 2;
    const rise = 14.0; // 鼓起高度
    final path = Path()
      ..moveTo(r, 0)
      ..lineTo(cx - hump - 22, 0)
      ..cubicTo(cx - hump + 4, 0, cx - hump + 6, -rise, cx, -rise)
      ..cubicTo(cx + hump - 6, -rise, cx + hump - 4, 0, cx + hump + 22, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w - r, h), radius: Radius.circular(r))
      ..lineTo(r, h)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..close();
    canvas.drawShadow(path, const Color(0xFF000000), 12, false);
    canvas.drawPath(path, Paint()..color = const Color(0xF21B1B20));
    canvas.drawPath(path, Paint()
      ..color = LL.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.hump != hump;
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
