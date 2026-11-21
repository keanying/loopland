import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:safe_device/safe_device.dart';
import 'package:safe_device/safe_device_config.dart';

import '../api/models.dart';

/// Device risk signals for `device` in `POST /v1/activities`.
///
/// - `rooted`: safe_device (Android: RootBeer; iOS: DTTJailbreakDetection).
/// - `emulator`: device_info_plus `isPhysicalDevice`, plus safe_device's
///   `isRealDevice`.
/// - `multi_open` (应用分身 / 双开 / VirtualApp-style containers): the app's
///   private data directory is not `/data/user/0/<own package>` — see
///   [multiOpenFromDataDir].
///
/// The mock-location check of safe_device is disabled: it would touch
/// location services, which must not run before the user's consent (the run
/// recorder reports per-fix `mocked` from geolocator instead).
Future<DeviceInfo> collectDevice(String deviceId) async {
  if (kIsWeb) return DeviceInfo(id: deviceId, model: 'web', os: 'web');
  final p = DeviceInfoPlugin();
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await p.androidInfo;
        final risk = await _risk(android: true);
        return DeviceInfo(
          id: deviceId,
          model: '${a.manufacturer} ${a.model}',
          os: 'Android ${a.version.release}',
          emulator: !a.isPhysicalDevice || risk.emulator,
          rooted: risk.rooted,
          multiOpen: risk.multiOpen,
        );
      case TargetPlatform.iOS:
        final i = await p.iosInfo;
        final risk = await _risk(android: false);
        return DeviceInfo(
          id: deviceId,
          model: i.utsname.machine,
          os: 'iOS ${i.systemVersion}',
          emulator: !i.isPhysicalDevice || risk.emulator,
          rooted: risk.rooted,
        );
      default:
        return DeviceInfo(id: deviceId, model: defaultTargetPlatform.name, os: defaultTargetPlatform.name);
    }
  } catch (_) {
    return DeviceInfo(id: deviceId);
  }
}

Future<({bool rooted, bool emulator, bool multiOpen})> _risk({required bool android}) async {
  var rooted = false, emulator = false, multiOpen = false;
  try {
    if (!SafeDevice.isInitiated) SafeDevice.init(const SafeDeviceConfig(mockLocationCheckEnabled: false));
    rooted = await SafeDevice.isJailBroken;
    emulator = !await SafeDevice.isRealDevice;
  } catch (_) {}
  if (android) {
    try {
      final dir = await getApplicationSupportDirectory();
      final pkg = (await PackageInfo.fromPlatform()).packageName;
      multiOpen = multiOpenFromDataDir(dir.path, pkg);
    } catch (_) {}
  }
  return (rooted: rooted, emulator: emulator, multiOpen: multiOpen);
}

/// Heuristic multi-open detection from the app's private data directory.
///
/// Normal: `/data/user/0/<pkg>/…`, `/data/data/<pkg>/…`, or adopted storage
/// `/mnt/expand/<uuid>/user/0/<pkg>/…`. A non-zero Android user id (MIUI /
/// ColorOS 双开 = 999, Samsung Dual Messenger = 95, Huawei 应用分身, work
/// profiles) or another package owning the directory (VirtualApp, 平行空间,
/// 多开分身) counts as multi-open. Unknown layouts return false.
bool multiOpenFromDataDir(String path, String packageName) {
  final m = RegExp(r'^/(?:data|mnt/expand/[^/]+)/(?:data|user(?:_de)?/(\d+))/([^/]+)').firstMatch(path);
  if (m == null) return false;
  final user = m.group(1);
  if (user != null && user != '0') return true;
  return m.group(2) != packageName;
}
