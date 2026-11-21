import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../coach/pose.dart';
import '../../core/theme.dart';

/// Draws the detected skeleton over the camera preview. The frame is fitted
/// like the preview (BoxFit.cover, centred) and flipped horizontally for the
/// mirrored front camera.
class SkeletonPainter extends CustomPainter {
  SkeletonPainter({required this.frame, this.mirrored = false, this.color = LL.lime, this.opacity = 1});

  final PoseFrame? frame;
  final bool mirrored;
  final Color color;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null || !f.hasPerson || f.width <= 0 || f.height <= 0) return;
    final scale = math.max(size.width / f.width, size.height / f.height);
    final dx = (size.width - f.width * scale) / 2, dy = (size.height - f.height * scale) / 2;
    Offset? at(Joint j) {
      final l = f.get(j);
      if (l == null) return null;
      final x = l.x * scale + dx;
      return Offset(mirrored ? size.width - x : x, l.y * scale + dy);
    }

    final bone = Paint()
      ..color = color.withValues(alpha: opacity)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (a, b) in skeletonBones) {
      final pa = at(a), pb = at(b);
      if (pa != null && pb != null) canvas.drawLine(pa, pb, bone);
    }
    // Neck + head (circle around the nose, sized by the shoulders).
    final ls = at(Joint.leftShoulder), rs = at(Joint.rightShoulder), nose = at(Joint.nose);
    if (ls != null && rs != null && nose != null) {
      final neck = Offset((ls.dx + rs.dx) / 2, (ls.dy + rs.dy) / 2);
      final r = math.max(10.0, (ls - rs).distance * 0.32);
      final head = Offset(nose.dx, nose.dy);
      final dir = head - neck;
      if (dir.distance > r) canvas.drawLine(neck, head - dir / dir.distance * r, bone);
      canvas.drawCircle(head, r, bone);
    }
    final dot = Paint()..color = LL.text.withValues(alpha: opacity);
    for (final j in Joint.values) {
      if (j == Joint.nose) continue;
      final p = at(j);
      if (p != null) canvas.drawCircle(p, 5, dot);
    }
  }

  @override
  bool shouldRepaint(SkeletonPainter old) =>
      old.frame != frame || old.mirrored != mirrored || old.color != color || old.opacity != opacity;
}

/// The camera card's background: grid lines and the four lavender corner
/// brackets of the design (where to stand).
class CoachGridPainter extends CustomPainter {
  const CoachGridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0xFF202027)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4, x = size.width * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final br = Paint()
      ..color = LL.lavender
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final l = size.width * 0.16, r = size.width * 0.84, t = size.height * 0.09, b = size.height * 0.91;
    const k = 30.0;
    for (final (x, y, sx, sy) in [(l, t, 1.0, 1.0), (r, t, -1.0, 1.0), (l, b, 1.0, -1.0), (r, b, -1.0, -1.0)]) {
      canvas.drawLine(Offset(x, y), Offset(x + k * sx, y), br);
      canvas.drawLine(Offset(x, y), Offset(x, y + k * sy), br);
    }
  }

  @override
  bool shouldRepaint(CoachGridPainter old) => false;
}

/// A standing figure (design placeholder before the camera sees anyone, and
/// for devices without a camera).
PoseFrame standingFrame({int tMs = 0, double width = 366, double height = 446, double lift = 0}) {
  Landmark p(double x, double y) => Landmark(x, y - lift);
  return PoseFrame(tMs: tMs, width: width, height: height, joints: {
    Joint.nose: p(183, 128),
    Joint.leftShoulder: p(168, 170),
    Joint.rightShoulder: p(198, 170),
    Joint.leftElbow: p(150, 215),
    Joint.rightElbow: p(216, 215),
    Joint.leftWrist: p(140, 250),
    Joint.rightWrist: p(226, 250),
    Joint.leftHip: p(172, 250),
    Joint.rightHip: p(194, 250),
    Joint.leftKnee: p(165, 310),
    Joint.rightKnee: p(201, 310),
    Joint.leftAnkle: p(160, 360),
    Joint.rightAnkle: p(206, 360),
  });
}
