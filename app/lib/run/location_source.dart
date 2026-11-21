import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../claim/gcj02.dart';
import '../core/env.dart';
import '../core/privacy.dart';

/// One location fix, already in GCJ-02.
class Fix {
  const Fix({
    required this.time,
    required this.lat,
    required this.lng,
    this.accuracy,
    this.speed,
    this.mocked = false,
  });
  final DateTime time;
  final double lat;
  final double lng;
  final double? accuracy;
  final double? speed;
  final bool mocked;
}

enum LocationPermissionResult { granted, denied, deniedForever, serviceDisabled }

/// Abstracts the GPS so the run screen can be tested with a fake.
abstract class LocationSource {
  Future<LocationPermissionResult> ensurePermission();

  /// Continuous fixes while a run is active. On Android this starts a
  /// foreground service with a persistent notification; on iOS background
  /// updates are enabled (UIBackgroundModes=location), so recording continues
  /// when the screen is locked.
  Stream<Fix> watch();

  Future<Fix?> current();

  Future<void> openSettings();
}

/// geolocator is never touched before the first-launch privacy agreement
/// ([LaunchPrivacy.agreed]); callers additionally check the server-side
/// location consent before starting a run.
class GeolocatorSource implements LocationSource {
  @override
  Future<LocationPermissionResult> ensurePermission() async {
    if (!LaunchPrivacy.agreed) return LocationPermissionResult.denied;
    if (!await Geolocator.isLocationServiceEnabled()) return LocationPermissionResult.serviceDisabled;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    // Background updates need "always" on iOS / Android 10+; ask once, but
    // "while in use" still works with the foreground service / iOS indicator.
    if (p == LocationPermission.whileInUse && !kIsWeb && Env.isIOS) {
      p = await Geolocator.requestPermission();
    }
    return switch (p) {
      LocationPermission.always || LocationPermission.whileInUse => LocationPermissionResult.granted,
      LocationPermission.deniedForever => LocationPermissionResult.deniedForever,
      _ => LocationPermissionResult.denied,
    };
  }

  LocationSettings _settings() {
    if (Env.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: '圈圈正在记录你的运动',
          notificationText: '锁屏后也会继续记录轨迹和圈地',
          notificationChannelName: '运动记录',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Env.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.fitness,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }

  static Fix _fix(Position p) {
    final g = wgs84ToGcj02(p.latitude, p.longitude);
    return Fix(
      time: p.timestamp,
      lat: g.lat,
      lng: g.lng,
      accuracy: p.accuracy,
      speed: p.speed >= 0 ? p.speed : null,
      mocked: p.isMocked,
    );
  }

  @override
  Stream<Fix> watch() => LaunchPrivacy.agreed
      ? Geolocator.getPositionStream(locationSettings: _settings()).map(_fix)
      : const Stream.empty();

  @override
  Future<Fix?> current() async {
    if (!LaunchPrivacy.agreed) return null;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return _fix(last);
      return _fix(await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10))));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> openSettings() => Geolocator.openAppSettings();
}

/// Replays a scripted list of fixes (tests, simulator demos).
class FakeLocationSource implements LocationSource {
  FakeLocationSource([this.fixes = const []]);
  final List<Fix> fixes;
  final _ctrl = StreamController<Fix>.broadcast();

  void emit(Fix f) => _ctrl.add(f);

  @override
  Future<LocationPermissionResult> ensurePermission() async => LocationPermissionResult.granted;

  @override
  Stream<Fix> watch() {
    if (fixes.isEmpty) return _ctrl.stream;
    return Stream.fromIterable(fixes);
  }

  @override
  Future<Fix?> current() async => fixes.isEmpty ? null : fixes.first;

  @override
  Future<void> openSettings() async {}
}
