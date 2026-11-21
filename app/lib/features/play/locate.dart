import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../claim/geo.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart';
import '../../widgets/common.dart';

/// Current position in GCJ-02 (the location source already converts), or
/// null with a toast when permission is missing or there is no fix.
Future<LatLng?> currentLocation(BuildContext context, WidgetRef ref) async {
  final src = ref.read(locationSourceProvider);
  final p = await src.ensurePermission();
  if (p != LocationPermissionResult.granted) {
    if (context.mounted) toast(context, '需要定位权限，才能确认你在附近');
    return null;
  }
  final f = await src.current();
  if (f == null) {
    if (context.mounted) toast(context, '暂时拿不到定位，到开阔的地方再试试');
    return null;
  }
  return LatLng(f.lat, f.lng);
}

/// "1.2 km" / "350 m".
String distanceText(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';
