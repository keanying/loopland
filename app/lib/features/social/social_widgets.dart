import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart';
import '../../api/community_models.dart';
import '../../claim/geo.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../widgets/cosmetics.dart';
import '../../widgets/l_icons.dart';

/// 1.3K / 18.6K / 1.2M style counts (as in the prototypes).
String compactCount(int n) {
  String one(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  if (n < 1000) return '$n';
  if (n < 1000000) return '${one(n / 1000)}K';
  return '${one(n / 1000000)}M';
}

const _avatarColors = [LL.orange, LL.lavender, LL.sky, LL.pink, LL.lime, LL.yellow];
Color avatarColor(int id) => _avatarColors[id.abs() % _avatarColors.length];

/// Absolute URL for media; dev storage may return `/v1/media/files/...`.
String mediaUrl(String url) => url.startsWith('/') ? '${Env.apiBase}$url' : url;

/// Round avatar: the user's photo, or the first character on a colour.
/// With an equipped `avatar_frame` (E-05) the frame is drawn around the photo
/// inside the same [size] (the ring option is dropped then).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, this.size = 44, this.ring = false, this.onTap});
  final UserBrief user;
  final double size;
  final bool ring;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = avatarColor(user.id);
    final name = user.nickname;
    final ch = name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1)).toUpperCase();
    Widget photo(double size) {
      Widget fallback() => Container(
            alignment: Alignment.center,
            color: color,
            child: Text(ch, style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: size * 0.42)),
          );
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: user.avatarUrl == null
              ? fallback()
              : Image.network(mediaUrl(user.avatarUrl!), fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback()),
        ),
      );
    }

    final frame = user.avatarFrame;
    if (frame != null && frame.isNotEmpty) {
      return Semantics(
        label: '$name的头像',
        child: GestureDetector(onTap: onTap, child: FramedAvatar(frameKey: frame, size: size, child: photo)),
      );
    }
    Widget img = photo(size);
    if (ring) {
      img = Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2.5)),
        child: img,
      );
    }
    return Semantics(
      label: '$name的头像',
      child: GestureDetector(onTap: onTap, child: img),
    );
  }
}

/// Opens a user's profile (D-07).
void openProfile(BuildContext context, UserBrief u) {
  if (u.isDeleted || u.id == 0) return;
  context.push('/users/${u.id}');
}

class ReviewBadge extends StatelessWidget {
  const ReviewBadge({super.key, required this.status, this.reason});
  final ReviewStatus status;
  final String? reason;
  @override
  Widget build(BuildContext context) {
    if (status == ReviewStatus.approved) return const SizedBox.shrink();
    final pending = status == ReviewStatus.pending;
    final text = pending ? '审核中' : '未通过${reason == null || reason!.isEmpty ? '' : '：$reason'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: pending ? const Color(0xFF3A3020) : const Color(0xFF3A1D22),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: pending ? LL.yellow : LL.red)),
    );
  }
}

class FollowButton extends StatelessWidget {
  const FollowButton({super.key, required this.following, required this.onTap, this.followedBy = false, this.height = 36});
  final bool following;
  final bool followedBy;
  final VoidCallback? onTap;
  final double height;
  @override
  Widget build(BuildContext context) {
    final label = following ? (followedBy ? '互相关注' : '已关注') : (followedBy ? '回关' : '关注');
    return SizedBox(
      height: height,
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          backgroundColor: following ? LL.card2 : LL.lime,
          foregroundColor: following ? LL.text2 : LL.ink,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, fontFamilyFallback: LL.fonts),
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }
}

/// A run's track on a dark "street grid" card. [progress] (0–1) draws only the
/// first part of the line (replay animation); with [times] the cut-off is by
/// time instead of by distance.
class TrackView extends StatelessWidget {
  const TrackView({
    super.key,
    required this.track,
    this.progress = 1,
    this.times,
    this.color = LL.orange,
    this.strokeWidth = 4,
    this.padding = 22,
    this.grid = true,
  });
  final List<LatLng> track;
  final double progress;
  final List<double>? times;
  final Color color;
  final double strokeWidth;
  final double padding;
  final bool grid;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: TrackPainter(
          track: track,
          progress: progress,
          times: times,
          color: color,
          strokeWidth: strokeWidth,
          padding: padding,
          grid: grid,
        ),
        child: const SizedBox.expand(),
      );
}

class TrackPainter extends CustomPainter {
  TrackPainter({
    required this.track,
    this.progress = 1,
    this.times,
    this.color = LL.orange,
    this.strokeWidth = 4,
    this.padding = 22,
    this.grid = true,
  });
  final List<LatLng> track;
  final double progress;
  final List<double>? times;
  final Color color;
  final double strokeWidth;
  final double padding;
  final bool grid;

  /// Track points in canvas coordinates (north up, aspect preserved).
  static List<Offset> fit(List<LatLng> track, Size size, double padding) {
    if (track.isEmpty) return const [];
    final proj = Projection(track.first);
    final pts = [for (final p in track) proj.forward(p)];
    var minX = pts.first.x, maxX = minX, minY = pts.first.y, maxY = minY;
    for (final p in pts) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    final w = math.max(maxX - minX, 1.0), h = math.max(maxY - minY, 1.0);
    final aw = math.max(size.width - 2 * padding, 1.0), ah = math.max(size.height - 2 * padding, 1.0);
    final s = math.min(aw / w, ah / h);
    final ox = (size.width - w * s) / 2, oy = (size.height - h * s) / 2;
    return [for (final p in pts) Offset(ox + (p.x - minX) * s, oy + (maxY - p.y) * s)];
  }

  void _grid(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF16161A));
    // A river band and a few skewed "streets", like the prototype thumbnails.
    final river = Path()
      ..moveTo(0, size.height * 0.62)
      ..cubicTo(size.width * 0.3, size.height * 0.55, size.width * 0.6, size.height * 0.72, size.width, size.height * 0.6)
      ..lineTo(size.width, size.height * 0.72)
      ..cubicTo(size.width * 0.6, size.height * 0.84, size.width * 0.3, size.height * 0.67, 0, size.height * 0.74)
      ..close();
    canvas.drawPath(river, Paint()..color = const Color(0xFF14202B));
    final street = Paint()
      ..color = const Color(0xFF24242A)
      ..strokeWidth = 6;
    canvas.drawLine(Offset(0, size.height * 0.24), Offset(size.width, size.height * 0.18), street);
    canvas.drawLine(Offset(size.width * 0.3, 0), Offset(size.width * 0.34, size.height), street);
    canvas.drawLine(Offset(size.width * 0.72, 0), Offset(size.width * 0.69, size.height), street);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (grid) _grid(canvas, size);
    final pts = fit(track, size, padding);
    if (pts.length < 2) return;
    final p = progress.clamp(0.0, 1.0);

    // Cut-off: how many whole segments, plus the fraction of the next one.
    final keys = <double>[];
    final t = times;
    if (t != null && t.length == pts.length) {
      keys.addAll(t);
    } else {
      var acc = 0.0;
      keys.add(0);
      for (var i = 1; i < pts.length; i++) {
        acc += (pts[i] - pts[i - 1]).distance;
        keys.add(acc);
      }
    }
    final total = keys.last <= 0 ? 1.0 : keys.last;
    final target = total * p;

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    var head = pts.first;
    for (var i = 1; i < pts.length; i++) {
      if (keys[i] <= target) {
        path.lineTo(pts[i].dx, pts[i].dy);
        head = pts[i];
      } else {
        final span = keys[i] - keys[i - 1];
        final f = span <= 0 ? 0.0 : (target - keys[i - 1]) / span;
        head = Offset.lerp(pts[i - 1], pts[i], f.clamp(0.0, 1.0))!;
        path.lineTo(head.dx, head.dy);
        break;
      }
    }
    // Glow + line.
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    if (p < 1) {
      canvas.drawCircle(head, strokeWidth * 2.2, Paint()..color = LL.text);
      canvas.drawCircle(head, strokeWidth * 1.4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant TrackPainter old) =>
      old.track != track || old.progress != progress || old.color != color || old.times != times;
}

/// Network image with a dark placeholder (and no error spam in tests).
class NetImage extends StatelessWidget {
  const NetImage({super.key, required this.url, this.fit = BoxFit.cover});
  final String url;
  final BoxFit fit;
  @override
  Widget build(BuildContext context) => Image.network(
        mediaUrl(url),
        fit: fit,
        loadingBuilder: (context, child, p) => p == null ? child : const ColoredBox(color: LL.card2),
        errorBuilder: (_, _, _) => const ColoredBox(
          color: LL.card2,
          child: Center(child: LIcon(LIcons.image, color: LL.text3)),
        ),
      );
}

/// Small rounded stat chip used on track thumbnails (10.4 km / 5'29").
class StatChip extends StatelessWidget {
  const StatChip(this.text, {super.key, this.color = LL.text});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xE60E0E10), borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: color)),
      );
}
