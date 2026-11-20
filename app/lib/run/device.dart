import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../api/models.dart';

/// Collects `device` for `POST /v1/activities`.
///
/// TODO(风控): root / jailbreak and multi-open (应用分身) detection need a
/// native check (e.g. a small plugin or a commercial device-fingerprint SDK);
/// until then `rooted` / `multi_open` are reported as false.
Future<DeviceInfo> collectDevice(String deviceId) async {
  if (kIsWeb) return DeviceInfo(id: deviceId, model: 'web', os: 'web');
  final p = DeviceInfoPlugin();
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await p.androidInfo;
        return DeviceInfo(
          id: deviceId,
          model: '${a.manufacturer} ${a.model}',
          os: 'Android ${a.version.release}',
          emulator: !a.isPhysicalDevice,
        );
      case TargetPlatform.iOS:
        final i = await p.iosInfo;
        return DeviceInfo(
          id: deviceId,
          model: i.utsname.machine,
          os: 'iOS ${i.systemVersion}',
          emulator: !i.isPhysicalDevice,
        );
      default:
        return DeviceInfo(id: deviceId, model: defaultTargetPlatform.name, os: defaultTargetPlatform.name);
    }
  } catch (_) {
    return DeviceInfo(id: deviceId);
  }
}
