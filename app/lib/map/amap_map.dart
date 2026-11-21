import 'dart:math' as math;

import 'package:amap_map/amap_map.dart' as amap;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:x_amap_base/x_amap_base.dart' as base;

import '../api/models.dart';
import '../claim/geo.dart';
import '../core/sdk_config.dart';
import '../core/theme.dart';
import 'territory_map.dart';

/// AMap (高德) implementation. Coordinates are GCJ-02 end to end, so no
/// conversion is needed here. Territories are drawn as SDK polygons; taps are
/// hit-tested on our side because SDK polygons are not tappable.
///
/// Dark custom style: export it in the AMap console (自定义地图 → 下载
/// style.data / style_extra.data), add the files as Flutter assets and set
/// `AMAP_STYLE_DATA` / `AMAP_STYLE_EXTRA_DATA` to their asset paths. Without
/// them the SDK's built-in night map type is used.
class AmapTerritoryMap extends StatefulWidget {
  const AmapTerritoryMap({
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

  /// Called only after the user accepted the in-app privacy dialog (see
  /// SdkBootstrap). The plugin forwards it to the SDK's
  /// `MapsInitializer.updatePrivacyShow/updatePrivacyAgree` (Android) /
  /// `AMapServices` privacy calls (iOS) when the first map view is created,
  /// i.e. before any map / location init. Until then [TerritoryMapView]
  /// renders the pure-Flutter fallback map. 高德合规要求.
  static void agreePrivacy() {
    _privacyAgreed = true;
    amap.AMapInitializer.updatePrivacyAgree(
        const base.AMapPrivacyStatement(hasContains: true, hasShow: true, hasAgree: true));
  }

  static bool _privacyAgreed = false;
  static bool get privacyAgreed => _privacyAgreed;

  static amap.CustomStyleOptions? _style;
  static bool _styleLoaded = false;

  /// Loads the custom style assets once (null when not configured / missing).
  static Future<amap.CustomStyleOptions?> loadStyle(SdkConfig c, {AssetBundle? bundle}) async {
    if (_styleLoaded) return _style;
    _styleLoaded = true;
    if (!c.amapStyleConfigured) return null;
    final b = bundle ?? rootBundle;
    try {
      final data = (await b.load(c.amapStyleData)).buffer.asUint8List();
      Uint8List? extra;
      if (c.amapStyleExtraData.isNotEmpty) {
        extra = (await b.load(c.amapStyleExtraData)).buffer.asUint8List();
      }
      return _style = amap.CustomStyleOptions(true, styleData: data, styleExtraData: extra);
    } catch (_) {
      return null; // asset missing → built-in night type
    }
  }

  @override
  State<AmapTerritoryMap> createState() => _AmapTerritoryMapState();
}

class _AmapTerritoryMapState extends State<AmapTerritoryMap> implements MapDelegate {
  amap.AMapController? _ctrl;
  Size _size = Size.zero;
  double _zoom = 15;
  base.LatLng? _target;

  static base.LatLng _ll(LatLng p) => base.LatLng(p.lat, p.lng);

  amap.CustomStyleOptions? _style = AmapTerritoryMap._style;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom;
    widget.controller?.attach(this);
    if (!AmapTerritoryMap._styleLoaded) {
      AmapTerritoryMap.loadStyle(SdkConfig.current).then((s) {
        if (mounted && s != null) setState(() => _style = s);
      });
    }
  }

  @override
  void dispose() {
    widget.controller?.detach(this);
    super.dispose();
  }

  @override
  void zoomBy(double delta) =>
      _ctrl?.moveCamera(delta > 0 ? amap.CameraUpdate.zoomIn() : amap.CameraUpdate.zoomOut());

  @override
  void moveTo(LatLng target, {double? zoom}) => _ctrl?.moveCamera(
      zoom == null ? amap.CameraUpdate.newLatLng(_ll(target)) : amap.CameraUpdate.newLatLngZoom(_ll(target), zoom));

  @override
  void fitPoints(List<LatLng> pts) {
    var minLat = pts.first.lat, maxLat = minLat, minLng = pts.first.lng, maxLng = minLng;
    for (final p in pts) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    _ctrl?.moveCamera(amap.CameraUpdate.newLatLngBounds(
        base.LatLngBounds(southwest: base.LatLng(minLat, minLng), northeast: base.LatLng(maxLat, maxLng)), 48));
  }

  Future<void> _reportBounds() async {
    final c = _ctrl;
    if (c == null || _size.isEmpty || widget.onBoundsChanged == null) return;
    try {
      final sw = await c.fromScreenCoordinate(amap.ScreenCoordinate(x: 0, y: _size.height.toInt()));
      final ne = await c.fromScreenCoordinate(amap.ScreenCoordinate(x: _size.width.toInt(), y: 0));
      widget.onBoundsChanged!(MapBounds(sw.longitude, sw.latitude, ne.longitude, ne.latitude));
    } catch (_) {
      // Fall back to an estimate from zoom.
      final t = _target ?? _ll(widget.initialCenter);
      final mpp = 156543.03392 * math.cos(t.latitude * math.pi / 180) / math.pow(2, _zoom);
      final dLat = _size.height / 2 * mpp / 111320;
      final dLng = _size.width / 2 * mpp / (111320 * math.cos(t.latitude * math.pi / 180));
      widget.onBoundsChanged!(MapBounds(t.longitude - dLng, t.latitude - dLat, t.longitude + dLng, t.latitude + dLat));
    }
  }

  Set<amap.Polygon> _polygons() {
    final out = <amap.Polygon>{};
    for (final t in widget.layers.territories) {
      final color = relationColor(t.relation);
      final selected = t.id == widget.layers.selectedId;
      for (final poly in t.polygons) {
        if (poly.isEmpty || poly.first.length < 3) continue;
        out.add(amap.Polygon(
          points: [for (final p in poly.first) _ll(p)],
          strokeWidth: selected ? 6 : 4,
          strokeColor: color,
          fillColor: color.withValues(alpha: selected ? 0.5 : 0.32),
        ));
      }
    }
    for (final ring in widget.layers.loops) {
      if (ring.length < 3) continue;
      out.add(amap.Polygon(
        points: [for (final p in ring) _ll(p)],
        strokeWidth: 4,
        strokeColor: LL.lime,
        fillColor: LL.lime.withValues(alpha: 0.28),
      ));
    }
    return out;
  }

  Set<amap.Polyline> _polylines() {
    final out = <amap.Polyline>{};
    final t = widget.layers.track;
    if (t.length >= 2) {
      out.add(amap.Polyline(points: [for (final p in t) _ll(p)], width: 10, color: LL.lime, capType: amap.CapType.round));
    }
    final a = widget.layers.hintFrom, b = widget.layers.hintTarget;
    if (a != null && b != null) {
      out.add(amap.Polyline(
          points: [_ll(a), _ll(b)], width: 6, color: LL.lavender, dashLineType: amap.DashLineType.square));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    amap.AMapInitializer.init(context,
        apiKey: base.AMapApiKey(iosKey: SdkConfig.current.amapIosKey, androidKey: SdkConfig.current.amapAndroidKey));
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      return amap.AMapWidget(
        initialCameraPosition: amap.CameraPosition(target: _ll(widget.initialCenter), zoom: widget.initialZoom),
        mapType: amap.MapType.night,
        customStyleOptions: _style,
        compassEnabled: false,
        scaleEnabled: false,
        rotateGesturesEnabled: false,
        tiltGesturesEnabled: false,
        scrollGesturesEnabled: widget.interactive,
        zoomGesturesEnabled: widget.interactive,
        touchPoiEnabled: false,
        myLocationStyleOptions: amap.MyLocationStyleOptions(widget.layers.myLocation != null),
        polygons: _polygons(),
        polylines: _polylines(),
        onMapCreated: (ctrl) {
          _ctrl = ctrl;
          _reportBounds();
        },
        onCameraMoveEnd: (pos) {
          _zoom = pos.zoom;
          _target = pos.target;
          _reportBounds();
        },
        onTap: (ll) => widget.onTerritoryTap?.call(hitTest(widget.layers.territories, LatLng(ll.latitude, ll.longitude))),
      );
    });
  }
}
