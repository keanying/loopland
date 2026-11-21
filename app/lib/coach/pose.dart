import 'dart:math' as math;

/// The body landmarks the rep counters and the skeleton overlay use (a subset
/// of ML Kit's 33). Kept free of any plugin types so counters can be tested
/// with synthetic sequences.
enum Joint {
  nose,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
}

/// One landmark in image pixels (upright image, origin top-left, y down).
class Landmark {
  const Landmark(this.x, this.y, [this.likelihood = 1]);
  final double x;
  final double y;

  /// 0..1, ML Kit's in-frame likelihood.
  final double likelihood;

  @override
  String toString() => 'Landmark(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)}, ${likelihood.toStringAsFixed(2)})';
}

/// The landmarks found in one camera frame. Frames only live in memory: the
/// image itself is never kept, only these coordinates, and only for the
/// current set.
class PoseFrame {
  const PoseFrame({
    required this.tMs,
    required this.joints,
    this.width = 480,
    this.height = 640,
    this.luma,
  });

  /// Monotonic timestamp in milliseconds.
  final int tMs;

  /// Empty when no person was detected.
  final Map<Joint, Landmark> joints;

  /// Size of the upright image the coordinates refer to.
  final double width;
  final double height;

  /// Mean brightness 0..255 of the frame (sampled), when the source knows it.
  final double? luma;

  bool get hasPerson => joints.isNotEmpty;

  /// The landmark when it is confidently detected.
  Landmark? get(Joint j, {double minLikelihood = minLikelihood}) {
    final l = joints[j];
    if (l == null || l.likelihood < minLikelihood) return null;
    return l;
  }

  /// Whether [j] is detected and inside the picture (with a small margin).
  bool inFrame(Joint j, {double margin = 0.02}) {
    final l = get(j);
    if (l == null) return false;
    return l.x >= -margin * width &&
        l.x <= width * (1 + margin) &&
        l.y >= -margin * height &&
        l.y <= height * (1 + margin);
  }

  static const minLikelihood = 0.5;
}

/// Lines of the skeleton overlay.
const skeletonBones = <(Joint, Joint)>[
  (Joint.leftShoulder, Joint.rightShoulder),
  (Joint.leftShoulder, Joint.leftElbow),
  (Joint.leftElbow, Joint.leftWrist),
  (Joint.rightShoulder, Joint.rightElbow),
  (Joint.rightElbow, Joint.rightWrist),
  (Joint.leftShoulder, Joint.leftHip),
  (Joint.rightShoulder, Joint.rightHip),
  (Joint.leftHip, Joint.rightHip),
  (Joint.leftHip, Joint.leftKnee),
  (Joint.leftKnee, Joint.leftAnkle),
  (Joint.rightHip, Joint.rightKnee),
  (Joint.rightKnee, Joint.rightAnkle),
];

/// Angle ABC at [b] in degrees (0..180).
double angleAt(Landmark a, Landmark b, Landmark c) {
  final v1x = a.x - b.x, v1y = a.y - b.y;
  final v2x = c.x - b.x, v2y = c.y - b.y;
  final n1 = math.sqrt(v1x * v1x + v1y * v1y), n2 = math.sqrt(v2x * v2x + v2y * v2y);
  if (n1 == 0 || n2 == 0) return 180;
  final cos = ((v1x * v2x + v1y * v2y) / (n1 * n2)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

/// Elevation of the segment [from]→[to] above the image horizontal, degrees
/// 0 (flat) .. 90 (vertical), regardless of direction.
double elevation(Landmark from, Landmark to) {
  final dx = (to.x - from.x).abs(), dy = (to.y - from.y).abs();
  if (dx == 0 && dy == 0) return 0;
  return math.atan2(dy, dx) * 180 / math.pi;
}

double distance(Landmark a, Landmark b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

Landmark midpoint(Landmark a, Landmark b) =>
    Landmark((a.x + b.x) / 2, (a.y + b.y) / 2, math.min(a.likelihood, b.likelihood));
