import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Accent colour per monster kind (badges, HP bars on the map).
Color monsterColor(String kind) => switch (kind) {
      'bat' => const Color(0xFF8E7BE0),
      'smog' => const Color(0xFF8A8A94),
      'sugar' => LL.pink,
      _ => const Color(0xFFFF6A3D),
    };

const _ink = Color(0xFF121212);
const _white = Color(0xFFF4F4F5);

/// Draws one of the four city monsters (sofa / bat / smog / sugar) into
/// [dst]. Mirrors the prototype's CardArt SVG figures (viewBox 0 0 100 120,
/// figure inside x 6–94, y 4–104) as canvas paths, so the same art works in
/// widgets, in the fallback map painter and in AMap marker bitmaps.
void paintMonster(Canvas canvas, Rect dst, String kind) {
  canvas.save();
  final s = dst.shortestSide / 100;
  canvas.translate(dst.center.dx - 50 * s, dst.center.dy - 54 * s);
  canvas.scale(s);

  Paint fill(Color c) => Paint()..color = c;
  Paint stroke([double w = 2.2, Color c = _ink]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  void shape(Path p, Color? c, {double w = 2.2}) {
    if (c != null) canvas.drawPath(p, fill(c));
    canvas.drawPath(p, stroke(w));
  }

  void rrect(double x, double y, double w, double h, double r, Color c) =>
      shape(Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r))), c);
  void circle(double x, double y, double r, Color c, {bool outline = true}) {
    canvas.drawCircle(Offset(x, y), r, fill(c));
    if (outline) canvas.drawCircle(Offset(x, y), r, stroke());
  }

  void line(List<double> xy, {double w = 2.2, Color c = _ink}) {
    final p = Path()..moveTo(xy[0], xy[1]);
    for (var i = 2; i < xy.length; i += 2) {
      p.lineTo(xy[i], xy[i + 1]);
    }
    canvas.drawPath(p, stroke(w, c));
  }

  Path poly(List<double> xy) {
    final p = Path()..moveTo(xy[0], xy[1]);
    for (var i = 2; i < xy.length; i += 2) {
      p.lineTo(xy[i], xy[i + 1]);
    }
    return p..close();
  }

  switch (kind) {
    case 'bat':
      shape(
          Path()
            ..moveTo(76, 18)
            ..arcToPoint(const Offset(84, 32), radius: const Radius.circular(10), largeArc: true, clockwise: false)
            ..arcToPoint(const Offset(76, 18), radius: const Radius.circular(8), largeArc: true)
            ..close(),
          LL.yellow);
      for (final m in [1.0, -1.0]) {
        double x(double v) => m == 1 ? v : 100 - v;
        shape(
            Path()
              ..moveTo(x(48), 62)
              ..cubicTo(x(34), 40, x(16), 42, x(6), 56)
              ..cubicTo(x(14), 58, x(18), 64, x(20), 72)
              ..cubicTo(x(26), 66, x(32), 66, x(36), 72)
              ..cubicTo(x(40), 66, x(44), 64, x(48), 62)
              ..close(),
            const Color(0xFF8E7BE0));
      }
      shape(poly([40, 50, 36, 36, 46, 46]), LL.yellow);
      shape(poly([60, 50, 64, 36, 54, 46]), LL.yellow);
      circle(50, 66, 18, const Color(0xFF5B3E8C));
      circle(50, 60, 9, _white);
      circle(50, 61, 4.5, const Color(0xFFFF6A3D));
      circle(50, 61, 2, _ink, outline: false);
      canvas.drawPath(
          Path()
            ..moveTo(40, 74)
            ..quadraticBezierTo(50, 82, 60, 74),
          stroke());
      shape(poly([44, 76, 46, 81, 48, 77]), _white, w: 1.2);
      shape(poly([52, 77, 54, 81, 56, 76]), _white, w: 1.2);
      line([44, 84, 44, 96]);
      line([56, 84, 56, 96]);
    case 'smog':
      final cloud = Path()
        ..moveTo(22, 76)
        ..arcToPoint(const Offset(26, 49), radius: const Radius.circular(14))
        ..arcToPoint(const Offset(54, 39), radius: const Radius.circular(16))
        ..arcToPoint(const Offset(78, 49), radius: const Radius.circular(14))
        ..arcToPoint(const Offset(80, 76), radius: const Radius.circular(13))
        ..close();
      shape(cloud, const Color(0xFF8A8A94));
      circle(50, 56, 12, _white);
      circle(52, 57, 6, LL.lime);
      circle(52, 57, 2.6, _ink, outline: false);
      line([36, 44, 44, 48], w: 3);
      line([64, 44, 56, 48], w: 3);
      canvas.drawPath(
          Path()
            ..moveTo(38, 70)
            ..quadraticBezierTo(50, 64, 62, 70),
          stroke());
      for (final (x, h) in [(30.0, 8.0), (48.0, 14.0), (66.0, 6.0)]) {
        shape(
            Path()
              ..moveTo(x, 76)
              ..lineTo(x, 76 + h)
              ..arcToPoint(Offset(x + 6, 76 + h), radius: const Radius.circular(3), clockwise: false)
              ..lineTo(x + 6, 76),
            const Color(0xFF8A8A94));
      }
    case 'sugar':
      circle(50, 22, 6, const Color(0xFFFF6A3D));
      canvas.drawPath(
          Path()
            ..moveTo(50, 16)
            ..quadraticBezierTo(54, 8, 60, 8),
          stroke());
      shape(
          Path()
            ..moveTo(24, 64)
            ..cubicTo(16, 52, 30, 40, 38, 46)
            ..cubicTo(40, 30, 60, 30, 62, 46)
            ..cubicTo(70, 40, 84, 52, 76, 64)
            ..close(),
          const Color(0xFFF4E9D8));
      shape(poly([26, 64, 34, 98, 66, 98, 74, 64]), LL.pink);
      line([38, 64, 42, 98], w: 1.4);
      line([50, 64, 50, 98], w: 1.4);
      line([62, 64, 58, 98], w: 1.4);
      line([36, 72, 46, 76], w: 3);
      line([64, 72, 54, 76], w: 3);
      circle(42, 79, 3, _ink, outline: false);
      circle(58, 79, 3, _ink, outline: false);
      shape(poly([40, 88, 60, 88, 56, 94, 44, 94]), _ink);
      shape(poly([43, 88, 45, 92, 47, 88]), _white, w: 1);
      shape(poly([53, 88, 55, 92, 57, 88]), _white, w: 1);
      circle(34, 54, 2, LL.sky, outline: false);
      circle(52, 44, 2, LL.yellow, outline: false);
      circle(66, 54, 2, LL.lime, outline: false);
    default: // sofa
      rrect(22, 36, 56, 30, 9, LL.orange);
      rrect(18, 60, 64, 26, 8, LL.orange);
      rrect(10, 54, 14, 34, 6, const Color(0xFFFF6A3D));
      rrect(76, 54, 14, 34, 6, const Color(0xFFFF6A3D));
      rrect(22, 86, 6, 10, 0, const Color(0xFF2A2A31));
      rrect(72, 86, 6, 10, 0, const Color(0xFF2A2A31));
      circle(40, 50, 7, _white);
      circle(60, 50, 7, _white);
      circle(41, 52, 3, _ink, outline: false);
      circle(59, 52, 3, _ink, outline: false);
      line([32, 40, 46, 44], w: 3);
      line([68, 40, 54, 44], w: 3);
      shape(poly([32, 66, 68, 66, 63, 78, 37, 78]), _ink);
      for (final x in [36.0, 46.0, 56.0]) {
        shape(poly([x, 66, x + 3, 72, x + 6, 66]), _white, w: 1.2);
      }
      canvas.drawPath(
          Path()
            ..moveTo(66, 78)
            ..quadraticBezierTo(68, 84, 66, 88),
          stroke(2.5, LL.sky));
  }
  canvas.restore();
}

/// A square monster badge: dark tile, coloured border, the monster.
void paintMonsterBadge(Canvas canvas, Rect r, String kind, {bool dimmed = false}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.22));
  canvas.drawRRect(rr, Paint()..color = const Color(0xFF16161B));
  canvas.drawRRect(
      rr,
      Paint()
        ..color = dimmed ? LL.text3 : monsterColor(kind)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width * 0.06);
  paintMonster(canvas, r.deflate(r.width * 0.1), kind);
}

class MonsterPainter extends CustomPainter {
  const MonsterPainter(this.kind, {this.badge = false});
  final String kind;
  final bool badge;
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    badge ? paintMonsterBadge(canvas, r, kind) : paintMonster(canvas, r, kind);
  }

  @override
  bool shouldRepaint(covariant MonsterPainter old) => old.kind != kind || old.badge != badge;
}

/// Monster figure as a widget.
class MonsterArt extends StatelessWidget {
  const MonsterArt({super.key, required this.kind, this.size = 64, this.badge = false});
  final String kind;
  final double size;
  final bool badge;
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: MonsterPainter(kind, badge: badge));
}

/// PNG bytes of a map marker for AMap (which needs bitmaps). Cached.
class MarkerBitmaps {
  MarkerBitmaps._();
  static final _cache = <String, Future<Uint8List>>{};

  static Future<Uint8List> _render(String key, Size size, void Function(Canvas c, Size s) draw) =>
      _cache[key] ??= () async {
        const ratio = 3.0;
        final rec = ui.PictureRecorder();
        final c = Canvas(rec)..scale(ratio);
        draw(c, size);
        final img = await rec.endRecording().toImage((size.width * ratio).ceil(), (size.height * ratio).ceil());
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        return bytes!.buffer.asUint8List();
      }();

  /// Monster badge with "沙发怪 · 38%" below.
  static Future<Uint8List> boss(String kind, String label) =>
      _render('boss:$kind:$label', const Size(96, 92), (c, s) {
        paintMonsterBadge(c, const Rect.fromLTWH(22, 0, 52, 52), kind);
        paintPill(c, Offset(s.width / 2, 72), label, monsterColor(kind));
      });

  static Future<Uint8List> chest() => _render('chest', const Size(40, 40), (c, s) => paintChest(c, Offset(s.width / 2, s.height / 2), 18));

  static Future<Uint8List> checkpoint(int index, String state) =>
      _render('cp:$index:$state', const Size(36, 36), (c, s) => paintCheckpoint(c, Offset(s.width / 2, s.height / 2), index, state));
}

/// Rounded label pill centred on [center].
void paintPill(Canvas canvas, Offset center, String text, Color color, {double fontSize = 11}) {
  final tp = TextPainter(
    text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w800, fontFamily: 'Roboto', fontFamilyFallback: LL.fonts)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: 140);
  final r = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: tp.width + 18, height: tp.height + 8), Radius.circular((tp.height + 8) / 2));
  canvas.drawRRect(r, Paint()..color = const Color(0xF0201712));
  canvas.drawRRect(
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4);
  tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
}

/// Gold energy chest (map marker).
void paintChest(Canvas canvas, Offset c, double r) {
  final box = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: r * 2, height: r * 2), Radius.circular(r * 0.4));
  canvas.drawRRect(box, Paint()..color = LL.yellow);
  canvas.drawRRect(
      box,
      Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
  final p = Paint()
    ..color = _ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.8
    ..strokeJoin = StrokeJoin.round;
  // Lid line + latch, like the Games.html chest icon.
  final s = r / 10;
  canvas.drawLine(c + Offset(-7 * s, -1 * s), c + Offset(7 * s, -1 * s), p);
  canvas.drawPath(
      Path()
        ..moveTo(c.dx - 7 * s, c.dy + 7 * s)
        ..lineTo(c.dx - 7 * s, c.dy - 1 * s)
        ..lineTo(c.dx - 5 * s, c.dy - 6 * s)
        ..lineTo(c.dx + 5 * s, c.dy - 6 * s)
        ..lineTo(c.dx + 7 * s, c.dy - 1 * s)
        ..lineTo(c.dx + 7 * s, c.dy + 7 * s)
        ..close(),
      p);
  canvas.drawLine(c + Offset(0, -1 * s), c + Offset(0, 7 * s), p);
}

/// Route checkpoint: numbered dot; `next` highlighted, `done` ticked.
void paintCheckpoint(Canvas canvas, Offset c, int index, String state) {
  final next = state == 'next', done = state == 'done';
  if (next) canvas.drawCircle(c, 17, Paint()..color = LL.sky.withValues(alpha: 0.3));
  canvas.drawCircle(c, 12, Paint()..color = done ? _ink : (next ? LL.sky : LL.night));
  canvas.drawCircle(
      c,
      12,
      Paint()
        ..color = LL.sky
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
  if (done) {
    canvas.drawPath(
        Path()
          ..moveTo(c.dx - 5, c.dy)
          ..lineTo(c.dx - 1.5, c.dy + 3.5)
          ..lineTo(c.dx + 5, c.dy - 3.5),
        Paint()
          ..color = LL.sky
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    return;
  }
  final tp = TextPainter(
    text: TextSpan(
        text: '${index + 1}',
        style: TextStyle(
            color: next ? _ink : LL.sky, fontSize: 12, fontWeight: FontWeight.w900, fontFamily: 'Roboto', fontFamilyFallback: LL.fonts)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
}
