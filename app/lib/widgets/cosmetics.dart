// V2 batch 4 (E-05 能量商城) cosmetics rendering: avatar frames (by
// `avatar_frame` key), territory skins (fill / stroke / pattern) and the map
// marker for my own location (by `equipped.map_marker` key). Shared by the
// avatar widget, both map renderers and the shop previews.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../api/perks_models.dart';
import '../core/theme.dart';

/// `#RRGGBB` / `#AARRGGBB` / `RRGGBB` → Color; null when unparsable.
Color? parseHexColor(String? s) {
  if (s == null) return null;
  var h = s.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

// ───────────────────────────── 头像框 ─────────────────────────────

enum FrameKind { ring, glow, sweep, flame, dashed, generic }

class FrameStyle {
  const FrameStyle(this.kind, this.colors);
  final FrameKind kind;
  final List<Color> colors;
}

/// The frame styles the App knows. Unknown keys get [genericFrame] (a
/// double lavender ring) so a new catalogue item still shows *a* frame.
const avatarFrames = <String, FrameStyle>{
  'frame_gold': FrameStyle(FrameKind.ring, [Color(0xFFFFE08A), Color(0xFFE0A33A), Color(0xFFFFC857)]),
  'frame_neon': FrameStyle(FrameKind.glow, [LL.lime, Color(0xFFA0D911)]),
  'frame_aurora': FrameStyle(FrameKind.sweep, [LL.lavender, LL.sky, LL.lime, LL.pink, LL.lavender]),
  'frame_flame': FrameStyle(FrameKind.flame, [LL.yellow, LL.orange, LL.red]),
  'frame_ice': FrameStyle(FrameKind.dashed, [LL.sky, Color(0xFFE6FAFF)]),
  // Server default catalogue (migrations/0010_perks_shop): gold / runner / night.
  'frame_runner': FrameStyle(FrameKind.dashed, [Color(0xFF52C41A), LL.lime]),
  'frame_night': FrameStyle(FrameKind.sweep, [Color(0xFF2F54EB), LL.lavender, Color(0xFF0E1A4A), Color(0xFF2F54EB)]),
};

const genericFrame = FrameStyle(FrameKind.generic, [LL.lavender, LL.text3]);

FrameStyle frameStyle(String key) => avatarFrames[key] ?? genericFrame;

/// Paints the frame of [key] around a circle of [radius] at [c]. The frame
/// occupies roughly `radius * 0.16` outside the circle.
void paintAvatarFrame(Canvas canvas, Offset c, double radius, String key) {
  final st = frameStyle(key);
  final w = math.max(2.0, radius * 0.14);
  final ringR = radius + w / 2;
  final rect = Rect.fromCircle(center: c, radius: ringR);
  Paint stroke(Color color, [double? width]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width ?? w;
  switch (st.kind) {
    case FrameKind.ring:
      canvas.drawCircle(
          c,
          ringR,
          Paint()
            ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, st.colors, [0, 0.55, 1])
            ..style = PaintingStyle.stroke
            ..strokeWidth = w);
      // Three small gems on top.
      for (final a in const [-math.pi / 2, -math.pi / 2 - 0.5, -math.pi / 2 + 0.5]) {
        final p = c + Offset(math.cos(a), math.sin(a)) * ringR;
        final s = w * (a == -math.pi / 2 ? 0.95 : 0.65);
        final gem = Path()
          ..moveTo(p.dx, p.dy - s)
          ..lineTo(p.dx + s * 0.8, p.dy)
          ..lineTo(p.dx, p.dy + s)
          ..lineTo(p.dx - s * 0.8, p.dy)
          ..close();
        canvas.drawPath(gem, Paint()..color = const Color(0xFFFFF4C2));
        canvas.drawPath(gem, stroke(const Color(0xFFB07A1E), 1));
      }
    case FrameKind.glow:
      canvas.drawCircle(
          c,
          ringR,
          Paint()
            ..color = st.colors.first.withValues(alpha: 0.55)
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 1.6
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.8));
      canvas.drawCircle(c, ringR, stroke(st.colors.first, w * 0.75));
    case FrameKind.sweep:
      canvas.drawCircle(
          c,
          ringR,
          Paint()
            ..shader = ui.Gradient.sweep(c, st.colors, [for (var i = 0; i < st.colors.length; i++) i / (st.colors.length - 1)])
            ..style = PaintingStyle.stroke
            ..strokeWidth = w);
    case FrameKind.flame:
      final n = 12;
      final path = Path();
      for (var i = 0; i <= n * 2; i++) {
        final a = i / (n * 2) * 2 * math.pi - math.pi / 2;
        final r = i.isEven ? radius + w * 1.5 : radius + w * 0.3;
        final p = c + Offset(math.cos(a), math.sin(a)) * r;
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
          path, Paint()..shader = ui.Gradient.radial(c, radius + w * 1.5, [st.colors[0], st.colors[1], st.colors[2]], [0.82, 0.92, 1]));
      canvas.drawCircle(c, radius + w * 0.15, stroke(st.colors[1], w * 0.5));
    case FrameKind.dashed:
      canvas.drawCircle(c, ringR, stroke(st.colors.first.withValues(alpha: 0.35), w));
      const segs = 16;
      for (var i = 0; i < segs; i++) {
        final a = i / segs * 2 * math.pi;
        canvas.drawArc(rect, a, math.pi / segs, false, stroke(st.colors[1], w * 0.7)..strokeCap = StrokeCap.round);
      }
    case FrameKind.generic:
      canvas.drawCircle(c, ringR, stroke(st.colors.first, w * 0.7));
      canvas.drawCircle(c, ringR + w * 0.6, stroke(st.colors[1], 1));
  }
}

/// Foreground painter used by UserAvatar: the avatar is inset so the frame
/// fits inside the widget's box.
class AvatarFramePainter extends CustomPainter {
  AvatarFramePainter(this.frameKey);
  final String frameKey;

  /// Fraction of the box the photo takes when a frame is drawn.
  static const inset = 0.78;

  @override
  void paint(Canvas canvas, Size size) =>
      paintAvatarFrame(canvas, size.center(Offset.zero), size.shortestSide * inset / 2, frameKey);

  @override
  bool shouldRepaint(covariant AvatarFramePainter old) => old.frameKey != frameKey;
}

/// Wraps an avatar of [size] with the frame of [frameKey] (no-op for null).
/// The total footprint stays [size].
class FramedAvatar extends StatelessWidget {
  const FramedAvatar({super.key, required this.frameKey, required this.size, required this.child});
  final String? frameKey;
  final double size;

  /// Built at `size * AvatarFramePainter.inset` when framed.
  final Widget Function(double size) child;

  @override
  Widget build(BuildContext context) {
    final k = frameKey;
    if (k == null || k.isEmpty) return child(size);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        foregroundPainter: AvatarFramePainter(k),
        child: Center(child: child(size * AvatarFramePainter.inset)),
      ),
    );
  }
}

// ───────────────────────────── 领地皮肤 ─────────────────────────────

/// Resolved colours of a territory: the skin's, or the relation colours.
class TerritoryColors {
  const TerritoryColors(this.fill, this.stroke, this.pattern);
  final Color fill, stroke;
  final String? pattern;

  static TerritoryColors of(CosmeticStyle? skin, Color relation) {
    final f = parseHexColor(skin?.fill);
    final s = parseHexColor(skin?.stroke);
    return TerritoryColors(f ?? relation, s ?? f ?? relation, skin?.pattern);
  }
}

/// Draws [pattern] (`grid | stripe(s) | dot(s) | wave(s) | hex`) inside [path] in
/// [color]. Unknown / null patterns draw nothing (solid skin).
void paintSkinPattern(Canvas canvas, Path path, String? pattern, Color color, {double spacing = 12}) {
  if (pattern == null || pattern.isEmpty || pattern == 'none' || pattern == 'solid') return;
  final b = path.getBounds();
  if (b.isEmpty || b.width > 6000 || b.height > 6000) return;
  final p = Paint()
    ..color = color.withValues(alpha: 0.55)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;
  canvas.save();
  canvas.clipPath(path);
  switch (pattern) {
    case 'grid' || 'grids':
      for (var x = b.left; x <= b.right; x += spacing) {
        canvas.drawLine(Offset(x, b.top), Offset(x, b.bottom), p);
      }
      for (var y = b.top; y <= b.bottom; y += spacing) {
        canvas.drawLine(Offset(b.left, y), Offset(b.right, y), p);
      }
    case 'stripes' || 'stripe':
      p.strokeWidth = spacing * 0.35;
      for (var x = b.left - b.height; x <= b.right; x += spacing) {
        canvas.drawLine(Offset(x, b.bottom), Offset(x + b.height, b.top), p);
      }
    case 'dots' || 'dot':
      final dot = Paint()..color = color.withValues(alpha: 0.7);
      var row = 0;
      for (var y = b.top; y <= b.bottom; y += spacing, row++) {
        for (var x = b.left + (row.isOdd ? spacing / 2 : 0); x <= b.right; x += spacing) {
          canvas.drawCircle(Offset(x, y), spacing * 0.14, dot);
        }
      }
    case 'waves' || 'wave':
      for (var y = b.top; y <= b.bottom + spacing; y += spacing) {
        final w = Path()..moveTo(b.left, y);
        for (var x = b.left; x <= b.right; x += 4) {
          w.lineTo(x, y + math.sin((x - b.left) / spacing * math.pi) * spacing * 0.3);
        }
        canvas.drawPath(w, p);
      }
    case 'hex':
      final r = spacing * 0.6;
      final h = r * math.sqrt(3);
      var col = 0;
      for (var x = b.left; x <= b.right + r; x += r * 1.5, col++) {
        for (var y = b.top + (col.isOdd ? h / 2 : 0); y <= b.bottom + h; y += h) {
          final hex = Path();
          for (var i = 0; i < 6; i++) {
            final a = i * math.pi / 3;
            final q = Offset(x + r * math.cos(a), y + r * math.sin(a));
            i == 0 ? hex.moveTo(q.dx, q.dy) : hex.lineTo(q.dx, q.dy);
          }
          canvas.drawPath(hex..close(), p);
        }
      }
  }
  canvas.restore();
}

/// A territory-shaped blob in the skin's colours (shop preview).
class SkinPreview extends StatelessWidget {
  const SkinPreview({super.key, required this.style, this.height = 84});
  final CosmeticStyle style;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: CustomPaint(painter: _SkinPreviewPainter(style), size: Size.infinite),
      );
}

class _SkinPreviewPainter extends CustomPainter {
  _SkinPreviewPainter(this.style);
  final CosmeticStyle style;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)), Paint()..color = const Color(0xFF141418));
    final road = Paint()
      ..color = const Color(0xFF26262D)
      ..strokeWidth = 3;
    canvas.drawLine(Offset(size.width * 0.15, 0), Offset(size.width * 0.3, size.height), road);
    canvas.drawLine(Offset(0, size.height * 0.7), Offset(size.width, size.height * 0.55), road);
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) * 0.38;
    final path = Path();
    const n = 7;
    for (var i = 0; i < n; i++) {
      final a = i / n * 2 * math.pi;
      final rr = r * (i.isEven ? 1.05 : 0.82);
      final p = c + Offset(math.cos(a) * rr * 1.5, math.sin(a) * rr);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    final tc = TerritoryColors.of(style, LL.lime);
    canvas.drawPath(path, Paint()..color = tc.fill.withValues(alpha: 0.38));
    paintSkinPattern(canvas, path, tc.pattern, tc.stroke, spacing: 9);
    canvas.drawPath(
        path,
        Paint()
          ..color = tc.stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _SkinPreviewPainter old) => old.style != style;
}

// ───────────────────────────── 地图标记 ─────────────────────────────

/// Marker styles for my own location. null = the default lavender dot;
/// unknown keys = a generic lime pin.
const mapMarkerKeys = ['marker_rabbit', 'marker_flame', 'marker_star', 'marker_bolt', 'marker_flag', 'marker_heart', 'marker_paw'];

/// Paints my location marker of [key] centred on [o]. [tint] overrides the
/// main colour (shop previews pass the item's `preview.fill`).
void paintMapMarker(Canvas canvas, Offset o, String? key, {Color? tint}) {
  if (key == null || key.isEmpty) {
    canvas.drawCircle(o, 18, Paint()..color = LL.lavender.withValues(alpha: 0.25));
    canvas.drawCircle(o, 9, Paint()..color = LL.text);
    canvas.drawCircle(o, 6.5, Paint()..color = LL.lavender);
    return;
  }
  final color = tint ??
      switch (key) {
        'marker_bolt' => LL.lime,
        'marker_star' => LL.yellow,
        'marker_flag' => LL.orange,
        'marker_heart' => LL.pink,
        'marker_paw' => LL.sky,
        'marker_rabbit' => LL.lavender,
        'marker_flame' => LL.orange,
        _ => LL.lime,
      };
  canvas.drawCircle(o, 22, Paint()..color = color.withValues(alpha: 0.22));
  canvas.drawCircle(o, 14, Paint()..color = LL.ink);
  canvas.drawCircle(o, 12.5, Paint()..color = color);
  final ink = Paint()..color = LL.ink;
  final inkStroke = Paint()
    ..color = LL.ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  switch (key) {
    case 'marker_bolt':
      canvas.drawPath(
          Path()
            ..moveTo(o.dx + 1.5, o.dy - 8)
            ..lineTo(o.dx - 5, o.dy + 1)
            ..lineTo(o.dx - 0.5, o.dy + 1)
            ..lineTo(o.dx - 1.5, o.dy + 8)
            ..lineTo(o.dx + 5, o.dy - 1)
            ..lineTo(o.dx + 0.5, o.dy - 1)
            ..close(),
          ink);
    case 'marker_star':
      final star = Path();
      for (var i = 0; i < 10; i++) {
        final a = -math.pi / 2 + i * math.pi / 5;
        final r = i.isEven ? 8.0 : 3.6;
        final p = o + Offset(math.cos(a), math.sin(a)) * r;
        i == 0 ? star.moveTo(p.dx, p.dy) : star.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(star..close(), ink);
    case 'marker_flag':
      canvas.drawLine(o + const Offset(-4, -7), o + const Offset(-4, 8), inkStroke);
      canvas.drawPath(
          Path()
            ..moveTo(o.dx - 4, o.dy - 7)
            ..lineTo(o.dx + 7, o.dy - 3.5)
            ..lineTo(o.dx - 4, o.dy)
            ..close(),
          ink);
    case 'marker_heart':
      canvas.drawPath(
          Path()
            ..moveTo(o.dx, o.dy + 7)
            ..cubicTo(o.dx - 10, o.dy, o.dx - 6, o.dy - 9, o.dx, o.dy - 3.5)
            ..cubicTo(o.dx + 6, o.dy - 9, o.dx + 10, o.dy, o.dx, o.dy + 7)
            ..close(),
          ink);
    case 'marker_paw':
      canvas.drawOval(Rect.fromCenter(center: o + const Offset(0, 3), width: 9, height: 7), ink);
      for (final d in const [Offset(-5, -2), Offset(-2, -6), Offset(2, -6), Offset(5, -2)]) {
        canvas.drawCircle(o + d, 1.9, ink);
      }
    case 'marker_rabbit':
      // Two ears + head.
      canvas.drawOval(Rect.fromCenter(center: o + const Offset(-3, -5), width: 3.6, height: 9), ink);
      canvas.drawOval(Rect.fromCenter(center: o + const Offset(3, -5), width: 3.6, height: 9), ink);
      canvas.drawCircle(o + const Offset(0, 3), 5.5, ink);
      canvas.drawCircle(o + const Offset(-2, 2.5), 1, Paint()..color = color);
      canvas.drawCircle(o + const Offset(2, 2.5), 1, Paint()..color = color);
    case 'marker_flame':
      canvas.drawPath(
          Path()
            ..moveTo(o.dx, o.dy - 9)
            ..cubicTo(o.dx + 8, o.dy - 2, o.dx + 7, o.dy + 8, o.dx, o.dy + 8)
            ..cubicTo(o.dx - 7, o.dy + 8, o.dx - 8, o.dy, o.dx - 3, o.dy - 4)
            ..cubicTo(o.dx - 2, o.dy - 1, o.dx, o.dy - 2, o.dx, o.dy - 9)
            ..close(),
          ink);
    default:
      canvas.drawCircle(o, 4, ink);
  }
}

class MarkerPreview extends StatelessWidget {
  const MarkerPreview({super.key, required this.markerKey, this.tint, this.height = 84});
  final String? markerKey;
  final Color? tint;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: CustomPaint(painter: _MarkerPreviewPainter(markerKey, tint), size: Size.infinite),
      );
}

class _MarkerPreviewPainter extends CustomPainter {
  _MarkerPreviewPainter(this.markerKey, this.tint);
  final String? markerKey;
  final Color? tint;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)), Paint()..color = const Color(0xFF141418));
    final road = Paint()
      ..color = const Color(0xFF26262D)
      ..strokeWidth = 4;
    canvas.drawLine(Offset(0, size.height * 0.62), Offset(size.width, size.height * 0.4), road);
    canvas.drawLine(Offset(size.width * 0.62, 0), Offset(size.width * 0.5, size.height), road);
    paintMapMarker(canvas, size.center(Offset.zero), markerKey, tint: tint);
  }

  @override
  bool shouldRepaint(covariant _MarkerPreviewPainter old) => old.markerKey != markerKey || old.tint != tint;
}

// ───────────────────────────── 补给站 ─────────────────────────────

/// Supply station icon (a cup in a rounded square); dimmed once claimed today.
void paintSupply(Canvas canvas, Offset c, {bool claimed = false, double r = 15}) {
  final bg = claimed ? LL.card2 : LL.pink;
  final fg = claimed ? LL.text3 : LL.ink;
  final box = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: r * 2, height: r * 2), Radius.circular(r * 0.5));
  canvas.drawRRect(box, Paint()..color = bg);
  canvas.drawRRect(
      box,
      Paint()
        ..color = LL.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
  final s = r / 15;
  final p = Paint()
    ..color = fg
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2 * s
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;
  // Cup + handle + steam.
  canvas.drawPath(
      Path()
        ..moveTo(c.dx - 7 * s, c.dy - 2 * s)
        ..lineTo(c.dx + 5 * s, c.dy - 2 * s)
        ..lineTo(c.dx + 4 * s, c.dy + 7 * s)
        ..lineTo(c.dx - 6 * s, c.dy + 7 * s)
        ..close(),
      p);
  canvas.drawArc(Rect.fromCircle(center: c + Offset(5.5 * s, 2 * s), radius: 2.8 * s), -math.pi / 2, math.pi, false, p);
  canvas.drawLine(c + Offset(-3 * s, -9 * s), c + Offset(-3 * s, -5 * s), p);
  canvas.drawLine(c + Offset(1 * s, -9 * s), c + Offset(1 * s, -5 * s), p);
  if (claimed) {
    canvas.drawCircle(c + Offset(r * 0.8, -r * 0.8), r * 0.42, Paint()..color = LL.lime);
    canvas.drawPath(
        Path()
          ..moveTo(c.dx + r * 0.6, c.dy - r * 0.8)
          ..lineTo(c.dx + r * 0.75, c.dy - r * 0.65)
          ..lineTo(c.dx + r * 1.0, c.dy - r * 0.95),
        Paint()
          ..color = LL.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round);
  }
}

/// PNG bitmaps for AMap markers (supplies, my location marker). Cached.
class PerkBitmaps {
  PerkBitmaps._();
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

  static Future<Uint8List> supply(bool claimed) =>
      _render('supply:$claimed', const Size(40, 40), (c, s) => paintSupply(c, s.center(Offset.zero), claimed: claimed, r: 16));

  static Future<Uint8List> myMarker(String? key) =>
      _render('me:$key', const Size(48, 48), (c, s) => paintMapMarker(c, s.center(Offset.zero), key));
}
