import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../api/models.dart';
import '../api/local_models.dart' show MapVenue;
import '../api/perks_models.dart';
import '../claim/geo.dart';
import '../core/env.dart';
import '../core/theme.dart';
import 'amap_map.dart';
import 'fallback_map.dart';

/// Visible area, used for `GET /v1/territories?bbox=`.
class MapBounds {
  const MapBounds(this.minLng, this.minLat, this.maxLng, this.maxLat);
  final double minLng, minLat, maxLng, maxLat;
  @override
  String toString() => '$minLng,$minLat,$maxLng,$maxLat';
}

/// Commands the map implementations understand.
abstract class MapDelegate {
  void zoomBy(double delta);
  void moveTo(LatLng target, {double? zoom});
  void fitPoints(List<LatLng> pts);
}

/// Imperative handle for the map (zoom buttons, "回到我的位置").
class TerritoryMapController {
  MapDelegate? _d;
  // ignore: use_setters_to_change_properties
  void attach(MapDelegate d) => _d = d;
  void detach(MapDelegate d) {
    if (_d == d) _d = null;
  }

  void zoomIn() => _d?.zoomBy(1);
  void zoomOut() => _d?.zoomBy(-1);
  void moveTo(LatLng target, {double? zoom}) => _d?.moveTo(target, zoom: zoom);
  void fitPoints(List<LatLng> pts) {
    if (pts.isNotEmpty) _d?.fitPoints(pts);
  }
}

/// Colour per `relation`.
Color relationColor(String relation) => switch (relation) {
      'mine' => LL.lime,
      'crew' => LL.lavender,
      'enemy' => LL.orange,
      _ => LL.text3,
    };

/// A tapped gameplay object (V2).
sealed class MapObjectHit {
  const MapObjectHit();
}

class BossHit extends MapObjectHit {
  const BossHit(this.boss);
  final MapBoss boss;
}

class ChestHit extends MapObjectHit {
  const ChestHit(this.chest);
  final MapChest chest;
}

class CheckpointHit extends MapObjectHit {
  const CheckpointHit(this.checkpoint);
  final MapCheckpoint checkpoint;
}

/// V2 batch 4 (A-16): a 补给站.
class SupplyHit extends MapObjectHit {
  const SupplyHit(this.supply);
  final MapSupply supply;
}

/// V2 batch 4 (C-08): a venue (据点) with its 馆主.
class VenueHit extends MapObjectHit {
  const VenueHit(this.venue);
  final MapVenue venue;
}

/// "沙发怪 · 38%" (remaining HP).
String bossLabel(MapBoss b) => '${b.name} · ${(b.hpFraction * 100).round()}%';

/// Polygon approximating a circle of [radiusM] (AMap has no circle overlay
/// in this plugin version).
List<LatLng> circleRing(LatLng c, double radiusM, {int n = 48}) {
  final dLat = radiusM / 111320;
  final dLng = radiusM / (111320 * math.cos(c.lat * math.pi / 180));
  return [
    for (var i = 0; i <= n; i++)
      LatLng(c.lat + dLat * math.sin(i / n * 2 * math.pi), c.lng + dLng * math.cos(i / n * 2 * math.pi)),
  ];
}

/// Everything a map draws. Shared by the AMap and the fallback renderer.
class MapLayers {
  const MapLayers({
    this.objects = const MapObjects(),
    this.routePath = const [],
    this.territories = const [],
    this.track = const [],
    this.loops = const [],
    this.hintFrom,
    this.hintTarget,
    this.myLocation,
    this.selectedId,
    this.myMarker,
  });
  final List<TerritorySummary> territories;

  /// V2: bosses, chests and route checkpoints.
  final MapObjects objects;

  /// V2: ordered checkpoints of a route (drawn as a dashed line).
  final List<LatLng> routePath;
  final List<LatLng> track;

  /// Closed loops of the current run (preview).
  final List<List<LatLng>> loops;
  final LatLng? hintFrom;
  final LatLng? hintTarget;
  final LatLng? myLocation;
  final int? selectedId;

  /// V2 batch 4 (E-05): equipped `map_marker` key for [myLocation]; null =
  /// the default dot.
  final String? myMarker;
}

/// The territory map. Uses the AMap SDK when a key for the current platform
/// is configured (`--dart-define=AMAP_ANDROID_KEY / AMAP_IOS_KEY`), otherwise
/// a pure-Flutter renderer on a stylised dark background.
class TerritoryMapView extends StatelessWidget {
  const TerritoryMapView({
    super.key,
    required this.layers,
    this.controller,
    this.initialCenter = const LatLng(31.2304, 121.4737),
    this.initialZoom = 15,
    this.onTerritoryTap,
    this.onBoundsChanged,
    this.onObjectTap,
    this.interactive = true,
  });

  final MapLayers layers;
  final TerritoryMapController? controller;
  final LatLng initialCenter;
  final double initialZoom;
  final ValueChanged<TerritorySummary?>? onTerritoryTap;
  final ValueChanged<MapBounds>? onBoundsChanged;

  /// Taps on bosses / chests / checkpoints (checked before territories).
  final ValueChanged<MapObjectHit>? onObjectTap;
  final bool interactive;

  /// Tests and screenshots force the fallback.
  static bool forceFallback = false;

  /// AMap only with a key for this platform AND after the privacy
  /// agreement (no SDK init before consent).
  static bool get usesAmap =>
      !forceFallback &&
      !kIsWeb &&
      Env.amapKey.isNotEmpty &&
      (Env.isAndroid || Env.isIOS) &&
      AmapTerritoryMap.privacyAgreed;

  @override
  Widget build(BuildContext context) {
    if (usesAmap) {
      return AmapTerritoryMap(
        layers: layers,
        controller: controller,
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        onTerritoryTap: onTerritoryTap,
        onBoundsChanged: onBoundsChanged,
        onObjectTap: onObjectTap,
        interactive: interactive,
      );
    }
    return FallbackTerritoryMap(
      layers: layers,
      controller: controller,
      initialCenter: initialCenter,
      initialZoom: initialZoom,
      onTerritoryTap: onTerritoryTap,
      onBoundsChanged: onBoundsChanged,
      onObjectTap: onObjectTap,
      interactive: interactive,
    );
  }
}

/// Ray casting point-in-polygon on lat/lng (fine at city scale).
bool ringContains(List<LatLng> ring, LatLng p) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.lat > p.lat) != (b.lat > p.lat) &&
        p.lng < (b.lng - a.lng) * (p.lat - a.lat) / (b.lat - a.lat) + a.lng) {
      inside = !inside;
    }
  }
  return inside;
}

/// Territory under [p]: outer ring contains it and no hole does. Smallest
/// match wins so a small territory inside a big one can still be tapped.
TerritorySummary? hitTest(List<TerritorySummary> ts, LatLng p) {
  TerritorySummary? best;
  for (final t in ts) {
    for (final poly in t.polygons) {
      if (poly.isEmpty || !ringContains(poly.first, p)) continue;
      if (poly.skip(1).any((hole) => ringContains(hole, p))) continue;
      if (best == null || t.areaM2 < best.areaM2) best = t;
    }
  }
  return best;
}

LatLng? centerOf(TerritorySummary t) {
  if (t.center != null) return t.center;
  if (t.polygons.isEmpty || t.polygons.first.isEmpty) return null;
  final ring = t.polygons.first.first;
  var lat = 0.0, lng = 0.0;
  for (final p in ring) {
    lat += p.lat;
    lng += p.lng;
  }
  return LatLng(lat / ring.length, lng / ring.length);
}
