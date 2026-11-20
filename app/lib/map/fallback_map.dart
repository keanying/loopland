import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../claim/geo.dart';
import '../core/theme.dart';
import 'territory_map.dart';

const double _ky = earthRadiusM * math.pi / 180; // metres per degree latitude

/// Web-mercator-like zoom → screen projection around a centre.
class MapView {
  const MapView(this.center, this.zoom, this.size);
  final LatLng center;
  final double zoom;
  final Size size;

  double get _kx => _ky * math.cos(center.lat * math.pi / 180);

  /// Metres per logical pixel.
  double get mpp => 156543.03392 * math.cos(center.lat * math.pi / 180) / math.pow(2, zoom);

  Offset toScreen(LatLng p) => Offset(
        size.width / 2 + (p.lng - center.lng) * _kx / mpp,
        size.height / 2 - (p.lat - center.lat) * _ky / mpp,
      );

  LatLng fromScreen(Offset o) => LatLng(
        center.lat - (o.dy - size.height / 2) * mpp / _ky,
        center.lng + (o.dx - size.width / 2) * mpp / _kx,
      );

  MapBounds get bounds {
    final sw = fromScreen(Offset(0, size.height));
    final ne = fromScreen(Offset(size.width, 0));
    return MapBounds(sw.lng, sw.lat, ne.lng, ne.lat);
  }
}

/// Pure-Flutter territory map: dark stylised streets, territory polygons,
/// the live track and loop preview, pan / pinch zoom / tap.
class FallbackTerritoryMap extends StatefulWidget {
  const FallbackTerritoryMap({
    super.key,
    required this.layers,
    this.controller,
    required this.initialCenter,
    required this.initialZoom,
    this.onTerritoryTap,
    this.onBoundsChanged,
    this.interactive = true,
  });

  final MapLayers layers;
  final TerritoryMapController? controller;
  final LatLng initialCenter;
  final double initialZoom;
  final ValueChanged<TerritorySummary?>? onTerritoryTap;
  final ValueChanged<MapBounds>? onBoundsChanged;
  final bool interactive;

  @override
  State<FallbackTerritoryMap> createState() => _FallbackTerritoryMapState();
}

class _FallbackTerritoryMapState extends State<FallbackTerritoryMap> implements MapDelegate {
  late LatLng _center = widget.initialCenter;
  late double _zoom = widget.initialZoom;
  late final double _refLat = widget.initialCenter.lat;
  Size _size = Size.zero;

  // gesture state
  late LatLng _startCenter;
  late double _startZoom;
  late Offset _startFocal;

  MapView get _view => MapView(_center, _zoom, _size);

  @override
  void initState() {
    super.initState();
    widget.controller?.attach(this);
  }

  @override
  void didUpdateWidget(covariant FallbackTerritoryMap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.detach(this);
      widget.controller?.attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller?.detach(this);
    super.dispose();
  }

  void _report() {
    if (_size.isEmpty) return;
    widget.onBoundsChanged?.call(_view.bounds);
  }

  @override
  void zoomBy(double delta) {
    setState(() => _zoom = (_zoom + delta).clamp(3.0, 19.0));
    _report();
  }

  @override
  void moveTo(LatLng target, {double? zoom}) {
    setState(() {
      _center = target;
      if (zoom != null) _zoom = zoom.clamp(3.0, 19.0);
    });
    _report();
  }

  @override
  void fitPoints(List<LatLng> pts) {
    if (pts.isEmpty || _size.isEmpty) return;
    var minLat = pts.first.lat, maxLat = minLat, minLng = pts.first.lng, maxLng = minLng;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    final c = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    final kx = _ky * math.cos(c.lat * math.pi / 180);
    final wM = math.max((maxLng - minLng) * kx, 50.0);
    final hM = math.max((maxLat - minLat) * _ky, 50.0);
    final mpp = math.max(wM / (_size.width * 0.8), hM / (_size.height * 0.7));
    final z = math.log(156543.03392 * math.cos(c.lat * math.pi / 180) / mpp) / math.ln2;
    moveTo(c, zoom: z);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startCenter = _center;
    _startZoom = _zoom;
    _startFocal = d.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final z = (_startZoom + math.log(d.scale) / math.ln2).clamp(3.0, 19.0);
    // Keep the lat/lng under the starting focal point under the finger.
    final anchor = MapView(_startCenter, _startZoom, _size).fromScreen(_startFocal);
    final v = MapView(_startCenter, z, _size);
    final now = v.toScreen(anchor);
    final shift = d.localFocalPoint - now;
    final c = v.fromScreen(Offset(_size.width / 2 - shift.dx, _size.height / 2 - shift.dy));
    setState(() {
      _zoom = z;
      _center = c;
    });
  }

  void _onTapUp(TapUpDetails d) {
    final ll = _view.fromScreen(d.localPosition);
    widget.onTerritoryTap?.call(hitTest(widget.layers.territories, ll));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      if (size != _size) {
        final first = _size.isEmpty;
        _size = size;
        if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _report());
      }
      final paint = CustomPaint(
        size: size,
        painter: TerritoryPainter(view: _view, layers: widget.layers, refLat: _refLat),
      );
      if (!widget.interactive) return ClipRect(child: paint);
      return ClipRect(
        child: Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) zoomBy(-e.scrollDelta.dy / 400);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: (_) => _report(),
            onTapUp: _onTapUp,
            onDoubleTap: () => zoomBy(1),
            child: paint,
          ),
        ),
      );
    });
  }
}

/// Paints the whole map. Public so golden/screenshot tests can use it.
class TerritoryPainter extends CustomPainter {
  TerritoryPainter({required this.view, required this.layers, required this.refLat});
  final MapView view;
  final MapLayers layers;
  final double refLat;

  static const _bg = Color(0xFF141418);
  static const _road = Color(0xFF26262D);
  static const _roadMajor = Color(0xFF30303A);
  static const _water = Color(0xFF13222E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    _paintCity(canvas, size);
    for (final t in layers.territories) {
      _paintTerritory(canvas, t, selected: t.id == layers.selectedId);
    }
    for (final l in layers.loops) {
      _paintLoop(canvas, l);
    }
    _paintTrack(canvas);
    _paintHint(canvas);
    for (final t in layers.territories) {
      _paintLabel(canvas, size, t);
    }
    if (layers.myLocation != null) _paintMe(canvas, view.toScreen(layers.myLocation!));
  }

  // ── stylised city: deterministic jittered street grid + a river ──
  static double _hash(int i) {
    var x = (i * 374761393) ^ 0x5bd1e995;
    x = (x ^ (x >> 13)) * 1274126177;
    return ((x ^ (x >> 16)) & 0xffff) / 0xffff;
  }

  void _paintCity(Canvas canvas, Size size) {
    final kx = _ky * math.cos(refLat * math.pi / 180);
    final b = view.bounds;
    final x0 = b.minLng * kx, x1 = b.maxLng * kx;
    final y0 = b.minLat * _ky, y1 = b.maxLat * _ky;
    Offset w(double x, double y) => view.toScreen(LatLng(y / _ky, x / kx));
    final mpp = view.mpp;
    final px = 1 / mpp; // pixels per metre

    // River: a sine band in world metres.
    final riverPath = Path();
    final riverBase = (refLat - 0.006) * _ky;
    const step = 40.0;
    var first = true;
    for (var x = x0 - step; x <= x1 + step; x += step) {
      final y = riverBase + 180 * math.sin(x / 900) + 90 * math.sin(x / 310);
      final p = w(x, y);
      if (first) {
        riverPath.moveTo(p.dx, p.dy);
        first = false;
      } else {
        riverPath.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        riverPath,
        Paint()
          ..color = _water
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(6, 140 * px)
          ..strokeCap = StrokeCap.round);

    void streets(double spacing, Color color, double widthM, double minWidth, double jitter) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = math.max(minWidth, widthM * px)
        ..strokeCap = StrokeCap.butt;
      final i0 = (x0 / spacing).floor() - 1, i1 = (x1 / spacing).ceil() + 1;
      if (i1 - i0 > 400) return;
      for (var i = i0; i <= i1; i++) {
        final x = i * spacing + (_hash(i) - 0.5) * jitter;
        final tilt = (_hash(i + 7) - 0.5) * spacing * 0.3;
        canvas.drawLine(w(x - tilt, y0 - spacing), w(x + tilt, y1 + spacing), paint);
      }
      final j0 = (y0 / spacing).floor() - 1, j1 = (y1 / spacing).ceil() + 1;
      if (j1 - j0 > 400) return;
      for (var j = j0; j <= j1; j++) {
        final y = j * spacing + (_hash(j + 101) - 0.5) * jitter;
        final tilt = (_hash(j + 13) - 0.5) * spacing * 0.3;
        canvas.drawLine(w(x0 - spacing, y - tilt), w(x1 + spacing, y + tilt), paint);
      }
    }

    if (mpp < 8) streets(180, _road, 10, 1, 60);
    if (mpp < 60) streets(900, _roadMajor, 22, 2, 200);
  }

  Path _ringPath(List<LatLng> ring) {
    final path = Path();
    for (var i = 0; i < ring.length; i++) {
      final o = view.toScreen(ring[i]);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    path.close();
    return path;
  }

  void _paintTerritory(Canvas canvas, TerritorySummary t, {bool selected = false}) {
    final color = relationColor(t.relation);
    for (final poly in t.polygons) {
      if (poly.isEmpty) continue;
      final path = _ringPath(poly.first);
      for (final hole in poly.skip(1)) {
        path.addPath(_ringPath(hole), Offset.zero);
      }
      path.fillType = PathFillType.evenOdd;
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: selected ? 0.5 : 0.32));
      canvas.drawPath(
          path,
          Paint()
            ..color = t.frozen ? LL.sky : color
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 3.5 : 2
            ..strokeJoin = StrokeJoin.round);
    }
  }

  void _paintLoop(Canvas canvas, List<LatLng> ring) {
    final path = _ringPath(ring);
    canvas.drawPath(path, Paint()..color = LL.lime.withValues(alpha: 0.28));
    _dashed(canvas, path, Paint()
      ..color = LL.lime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5);
  }

  void _paintTrack(Canvas canvas) {
    final t = layers.track;
    if (t.length < 2) return;
    final path = Path();
    for (var i = 0; i < t.length; i++) {
      final o = view.toScreen(t[i]);
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = LL.ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(
        path,
        Paint()
          ..color = LL.lime
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  void _paintHint(Canvas canvas) {
    if (layers.hintFrom == null || layers.hintTarget == null) return;
    final a = view.toScreen(layers.hintFrom!), b = view.toScreen(layers.hintTarget!);
    _dashed(
        canvas,
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy),
        Paint()
          ..color = LL.lavender
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
    canvas.drawCircle(b, 6, Paint()..color = LL.lavender);
    canvas.drawCircle(b, 3, Paint()..color = LL.night);
  }

  void _paintMe(Canvas canvas, Offset o) {
    canvas.drawCircle(o, 18, Paint()..color = LL.lavender.withValues(alpha: 0.25));
    canvas.drawCircle(o, 9, Paint()..color = LL.text);
    canvas.drawCircle(o, 6.5, Paint()..color = LL.lavender);
  }

  void _paintLabel(Canvas canvas, Size size, TerritorySummary t) {
    final c = centerOf(t);
    if (c == null || t.polygons.isEmpty || t.polygons.first.isEmpty) return;
    final o = view.toScreen(c);
    if (!(Offset.zero & size).inflate(40).contains(o)) return;
    // Only label territories that are big enough on screen.
    final ring = t.polygons.first.first;
    var minX = double.infinity, maxX = -double.infinity;
    for (final p in ring) {
      final s = view.toScreen(p);
      minX = math.min(minX, s.dx);
      maxX = math.max(maxX, s.dx);
    }
    if (maxX - minX < 56) return;
    final tp = TextPainter(
      text: TextSpan(
          text: t.name, style: const TextStyle(color: LL.text, fontSize: 12, fontWeight: FontWeight.w700)),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 120);
    final w = tp.width + 28, h = 26.0;
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: o, width: w, height: h), const Radius.circular(13));
    final color = relationColor(t.relation);
    canvas.drawRRect(r, Paint()..color = LL.night.withValues(alpha: 0.88));
    canvas.drawRRect(
        r,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    canvas.drawCircle(Offset(r.left + 12, o.dy), 4, Paint()..color = color);
    tp.paint(canvas, Offset(r.left + 20, o.dy - tp.height / 2));
  }

  static void _dashed(Canvas canvas, Path path, Paint paint, {double dash = 8, double gap = 6}) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant TerritoryPainter old) =>
      old.view.center != view.center ||
      old.view.zoom != view.zoom ||
      old.view.size != view.size ||
      old.layers != layers;
}
