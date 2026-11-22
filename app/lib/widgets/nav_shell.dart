import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import 'card_art.dart' show hasArt;
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

class _Bar extends StatelessWidget {
  const _Bar({required this.index, required this.onTap, required this.centerArt});
  final int index;
  final ValueChanged<int> onTap;
  final String centerArt;

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, String label) {
      final sel = index == i;
      return Expanded(
        child: Semantics(
          button: true,
          selected: sel,
          label: label,
          child: InkResponse(
            onTap: () => onTap(i),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: sel ? LL.text : LL.text3, size: 28),
              const SizedBox(height: 4),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: sel ? LL.lime : Colors.transparent, shape: BoxShape.circle),
              ),
            ]),
          ),
        ),
      );
    }

    const button = 84.0; // 中间「开始」按钮直径（含外圈）
    return SizedBox(
      height: NavShell.barHeight + 22,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.bottomCenter, children: [
        // 底栏：中间向上鼓起一个弧，托住「开始」按钮（同设计稿）
        SizedBox(
          height: NavShell.barHeight,
          width: double.infinity,
          child: CustomPaint(
            painter: _BarPainter(hump: button / 2 + 10),
            child: Row(children: [
              item(0, Icons.map_outlined, '领地'),
              item(1, Icons.content_copy_outlined, '图鉴'),
              const SizedBox(width: button + 12),
              item(3, Icons.groups_outlined, '社区'),
              item(4, Icons.person_outline_rounded, '我的'),
            ]),
          ),
        ),
        Positioned(
          bottom: NavShell.barHeight / 2 - button / 2 + 6,
          child: Semantics(
            button: true,
            selected: index == 2,
            label: '开始',
            child: GestureDetector(
              onTap: () => onTap(2),
              child: _StartButton(size: button, selected: index == 2, art: centerArt),
            ),
          ),
        ),
      ]),
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

/// 底栏背景：圆角胶囊，中间顶部向上鼓起一个平滑的弧。
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
