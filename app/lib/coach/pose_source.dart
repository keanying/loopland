import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'pose.dart';
import 'pose_source_platform.dart' if (dart.library.js_interop) 'pose_source_web.dart' as platform;

enum PoseSourceStatus {
  /// Camera running, frames are coming.
  ready,

  /// The user refused the camera permission.
  denied,

  /// No (front) camera, or the platform has no on-device pose detection
  /// (web, desktop).
  unavailable,
  error,
}

/// Where pose frames come from: the front camera + ML Kit on phones, a fake
/// in tests and screenshots. Frames are processed on the device only; no
/// image is uploaded or stored.
abstract class PoseSource {
  /// Opens the camera (asks for the permission the first time).
  Future<PoseSourceStatus> start();

  Stream<PoseFrame> get frames;

  /// Live camera picture, or null (the page draws its placeholder).
  Widget? buildPreview();

  /// Whether the preview is mirrored relative to the landmark coordinates
  /// (front camera) — the skeleton overlay flips x to match.
  bool get mirrored;

  Future<void> dispose();
}

/// No camera: timer + manual counting (web, desktop, devices without one).
class NoCameraPoseSource implements PoseSource {
  @override
  Future<PoseSourceStatus> start() async => PoseSourceStatus.unavailable;
  @override
  Stream<PoseFrame> get frames => const Stream.empty();
  @override
  Widget? buildPreview() => null;
  @override
  bool get mirrored => false;
  @override
  Future<void> dispose() async {}
}

/// Creates a fresh source for each session (overridden in tests).
final poseSourceFactoryProvider = Provider<PoseSource Function()>((ref) => platform.createPoseSource);
