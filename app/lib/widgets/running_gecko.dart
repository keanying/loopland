import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// 底栏「开始」按钮里原地奔跑的小壁虎（照搬原型 Main 的 SVG 动画：
/// 腿 0.64 秒摆一个来回、身体每半步颠一下、尾巴甩动、身后三道速度线）。
///
/// [t] 是一个步态周期内的进度 0..1。坐标沿用原型的 64×64 viewBox。
class RunningGeckoPainter extends CustomPainter {
  RunningGeckoPainter(this.t);
  final double t;

  static const _ink = Color(0xFF141414);
  static const _lime = Color(0xFFDCF26A);
  static const _skin = Color(0xFFFFC857);
  static const _farLeg = Color(0xFFE0A33A);
  static const _spot = Color(0xFFFF6A3D);

  /// 0 → 1 → 0 的三角波（SVG 里 values="a;b;a" 的线性插值）。
  static double tri(double p) => 1 - (2 * (p % 1) - 1).abs();

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fill(Color c) => Paint()..color = c;

  /// 一条腿：绕髋部 (px, py) 转 [deg] 度，先画黑色描边再画颜色。
  void _leg(Canvas c, double px, double py, double deg, List<Offset> pts, double outline, Color color, double inner) {
    c.save();
    c.translate(px, py);
    c.rotate(deg * math.pi / 180);
    c.translate(-px, -py);
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    c.drawPath(path, _stroke(_ink, outline));
    c.drawPath(path, _stroke(color, inner));
    c.restore();
  }

  Path _tail(double k) {
    // 两个关键帧之间插值：k=0 尾巴上扬，k=1 尾巴下摆
    double l(double a, double b) => a + (b - a) * k;
    return Path()
      ..moveTo(22, 37)
      ..cubicTo(15, l(39, 37), 12, l(33, 41), 7, l(35, 39))
      ..cubicTo(4, l(36, 38), 4, l(39, 35), 7, l(39, 35));
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64, size.height / 64);

    // 速度线（不随身体颠动）
    canvas.drawPath(
      Path()
        ..moveTo(5, 30)
        ..lineTo(12, 30)
        ..moveTo(3, 37)
        ..lineTo(11, 37)
        ..moveTo(6, 44)
        ..lineTo(12, 44),
      _stroke(_lime, 2.4),
    );

    final step = tri(t); // 0 → 1 → 0，一个步态周期
    canvas.translate(0, -1.6 * tri(t * 2)); // 每半步颠一下

    // 远侧两条腿（颜色深一点）
    _leg(canvas, 27, 40, 28 - 56 * step, const [Offset(27, 40), Offset(24, 50), Offset(28, 52)], 3.4, _farLeg, 1.4);
    _leg(canvas, 39, 39, -28 + 56 * step, const [Offset(39, 39), Offset(42, 49), Offset(46, 49)], 3.4, _farLeg, 1.4);

    // 尾巴
    final tail = _tail(step);
    canvas.drawPath(tail, _stroke(_ink, 6));
    canvas.drawPath(tail, _stroke(_skin, 3));

    // 身体（椭圆，逆时针转 14°）+ 斑点
    canvas.save();
    canvas.translate(32, 36);
    canvas.rotate(-14 * math.pi / 180);
    final body = Rect.fromCenter(center: Offset.zero, width: 24, height: 15);
    canvas.drawOval(body, _fill(_skin));
    canvas.drawOval(body, _stroke(_ink, 2.2));
    canvas.restore();
    canvas.drawCircle(const Offset(28, 35), 1.8, _fill(_spot));
    canvas.drawCircle(const Offset(34, 32.5), 1.5, _fill(_spot));

    // 近侧两条腿
    _leg(canvas, 30, 41, -30 + 60 * step, const [Offset(30, 41), Offset(27, 51), Offset(31, 53)], 3.6, _skin, 1.6);
    _leg(canvas, 41, 38, 30 - 60 * step, const [Offset(41, 38), Offset(45, 47), Offset(49, 46)], 3.6, _skin, 1.6);

    // 头、眼睛、嘴、头顶的小火花
    canvas.drawCircle(const Offset(45, 25), 9, _fill(_skin));
    canvas.drawCircle(const Offset(45, 25), 9, _stroke(_ink, 2.2));
    canvas.drawCircle(const Offset(48, 22), 4.2, _fill(Colors.white));
    canvas.drawCircle(const Offset(48, 22), 4.2, _stroke(_ink, 1.6));
    canvas.drawCircle(const Offset(49.3, 22), 2, _fill(_ink));
    canvas.drawPath(
      Path()
        ..moveTo(46, 30)
        ..quadraticBezierTo(50, 32.5, 53.5, 28.5),
      _stroke(_ink, 1.8),
    );
    canvas.drawPath(
      Path()
        ..moveTo(38, 18)
        ..relativeLineTo(3, -4)
        ..relativeLineTo(1, 3)
        ..relativeLineTo(3, -3),
      _stroke(_lime, 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(RunningGeckoPainter old) => old.t != t;
}
