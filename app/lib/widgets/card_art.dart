import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Card illustrations extracted from the prototype (05_原型源文件/CardArt).
const _artKeys = {
  'archer', 'knight', 'smith', 'monk', 'scout', 'banner', 'alchemist', 'farmer', //
  'tower', 'campfire', 'mill', 'chapel', 'well', 'tent', 'forge', 'house', //
  'gecko', 'axolotl', 'frog', 'spiky', 'firetail', 'nightnewt', //
  'sofa', 'bat', 'smog', 'sugar',
};

bool hasArt(String key) => _artKeys.contains(key);

/// 5:6 card. Unobtained cards are a dark silhouette with a "?" badge.
class CardArt extends StatelessWidget {
  const CardArt({super.key, required this.artKey, this.locked = false, this.width = 104});
  final String artKey;
  final bool locked;
  final double width;

  // Matches the prototype's feColorMatrix silhouette filter.
  static const _silhouette = ColorFilter.matrix([
    0, 0, 0, 0, 0.18 * 255, //
    0, 0, 0, 0, 0.18 * 255, //
    0, 0, 0, 0, 0.21 * 255, //
    0, 0, 0, 0.95, 0,
  ]);

  @override
  Widget build(BuildContext context) {
    final h = width * 1.2;
    final r = BorderRadius.circular(width * 0.1 < 8 ? 8 : width * 0.1);
    Widget art;
    if (!hasArt(artKey)) {
      art = Container(
        color: locked ? LL.card2 : LL.lavender,
        alignment: Alignment.center,
        child: Icon(Icons.auto_awesome_rounded, color: locked ? LL.text3 : LL.ink, size: width * 0.4),
      );
    } else if (locked) {
      art = ColoredBox(
        color: LL.card2,
        child: ColorFiltered(
          colorFilter: _silhouette,
          child: SvgPicture.asset('assets/art/${artKey}_fig.svg', fit: BoxFit.cover, width: width, height: h),
        ),
      );
    } else {
      art = SvgPicture.asset('assets/art/$artKey.svg', fit: BoxFit.cover, width: width, height: h);
    }
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(borderRadius: r, border: Border.all(color: LL.ink, width: 2)),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(fit: StackFit.expand, children: [
          art,
          if (locked)
            Center(
              child: Container(
                width: width * 0.3,
                height: width * 0.3,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: LL.night.withValues(alpha: 0.85), shape: BoxShape.circle),
                child: Text('?', style: TextStyle(fontSize: width * 0.16, fontWeight: FontWeight.w900, color: LL.text)),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Medal badge (no prototype art for medals).
class MedalArt extends StatelessWidget {
  const MedalArt({super.key, required this.obtained, this.width = 104, this.label = ''});
  final bool obtained;
  final double width;
  final String label;
  @override
  Widget build(BuildContext context) {
    final h = width * 1.2;
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(
        color: obtained ? LL.yellow : LL.card2,
        borderRadius: BorderRadius.circular(width * 0.1),
        border: Border.all(color: LL.ink, width: 2),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.military_tech_rounded, size: width * 0.5, color: obtained ? LL.ink : LL.text3),
        if (label.isNotEmpty)
          Text(obtained ? label : '?',
              style: TextStyle(fontWeight: FontWeight.w900, color: obtained ? LL.ink : LL.text3, fontSize: width * 0.13)),
      ]),
    );
  }
}

/// The brand mark (double ring). Drawn in code because flutter_svg does not
/// support the masks used in the SVG source.
class LoopMark extends StatelessWidget {
  const LoopMark({super.key, this.size = 44});
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size(size * 74 / 52, size), painter: _MarkPainter());
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 12 22 74 52
    final s = size.height / 52;
    Offset p(double x, double y) => Offset((x - 12) * s, (y - 22) * s);
    final bounds = Offset.zero & size;
    // Lime disc with the white ring's surroundings cut out (mask cutDisc).
    canvas.saveLayer(bounds, Paint());
    canvas.drawCircle(p(62, 50), 21 * s, Paint()..color = LL.lime);
    canvas.drawCircle(p(38, 50), 19 * s,
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = 15 * s);
    canvas.restore();
    // White ring with a gap for the runner dot (mask cutRing).
    canvas.saveLayer(bounds, Paint());
    canvas.drawCircle(p(38, 50), 19 * s,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8 * s);
    canvas.drawCircle(p(38, 31), 7.5 * s, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
    canvas.drawCircle(p(38, 31), 5 * s, Paint()..color = LL.lavender);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
