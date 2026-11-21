import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart' as mlkit;
import 'package:material_ui/material_ui.dart';

import 'pose.dart';
import 'pose_source.dart';

/// Phones: front camera + ML Kit; elsewhere no camera.
PoseSource createPoseSource() =>
    (Platform.isAndroid || Platform.isIOS) ? MlKitPoseSource() : NoCameraPoseSource();

/// Front camera frames → ML Kit pose detection (on-device, stream mode) →
/// [PoseFrame]s with only the landmark coordinates.
///
/// Privacy: each camera image is handed to ML Kit in memory and dropped right
/// after; nothing is written to disk or sent over the network.
///
/// Frames that arrive while the previous one is still being processed are
/// skipped (ML Kit runs at whatever rate the phone manages, typically
/// 10–25 fps), so a slow phone just counts with fewer samples.
class MlKitPoseSource implements PoseSource {
  MlKitPoseSource({this.preset = ResolutionPreset.medium});

  final ResolutionPreset preset;

  CameraController? _ctrl;
  CameraDescription? _camera;
  mlkit.PoseDetector? _detector;
  final _out = StreamController<PoseFrame>.broadcast();
  final _clock = Stopwatch()..start();
  bool _busy = false;
  bool _closed = false;
  bool _mirrored = true;

  @override
  Stream<PoseFrame> get frames => _out.stream;

  @override
  bool get mirrored => _mirrored;

  @override
  Future<PoseSourceStatus> start() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty || _closed) return PoseSourceStatus.unavailable;
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      _camera = cam;
      _mirrored = cam.lensDirection == CameraLensDirection.front;
      final ctrl = CameraController(
        cam,
        preset,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      _ctrl = ctrl;
      await ctrl.initialize();
      if (_closed) {
        await ctrl.dispose();
        return PoseSourceStatus.error;
      }
      _detector = mlkit.PoseDetector(
        options: mlkit.PoseDetectorOptions(mode: mlkit.PoseDetectionMode.stream, model: mlkit.PoseDetectionModel.base),
      );
      await ctrl.startImageStream(_onImage);
      return PoseSourceStatus.ready;
    } on CameraException catch (e) {
      debugPrint('coach camera: ${e.code} ${e.description}');
      final code = e.code.toLowerCase();
      if (code.contains('denied') || code.contains('restricted') || code.contains('permission')) {
        return PoseSourceStatus.denied;
      }
      return PoseSourceStatus.error;
    } on MissingPluginException {
      return PoseSourceStatus.unavailable;
    } catch (e) {
      debugPrint('coach camera: $e');
      return PoseSourceStatus.error;
    }
  }

  @override
  Widget? buildPreview() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return null;
    final size = c.value.previewSize; // landscape (w > h)
    if (size == null) return CameraPreview(c);
    // Portrait box filled edge to edge (BoxFit.cover), like the overlay.
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(width: size.height, height: size.width, child: CameraPreview(c)),
      ),
    );
  }

  void _onImage(CameraImage img) {
    if (_busy || _closed) return;
    _busy = true;
    _process(img).whenComplete(() => _busy = false);
  }

  Future<void> _process(CameraImage img) async {
    final det = _detector, cam = _camera, ctrl = _ctrl;
    if (det == null || cam == null || ctrl == null) return;
    final rotation = _rotation(cam, ctrl);
    final input = _inputImage(img, rotation);
    if (input == null) return;
    final luma = _luma(img);
    List<mlkit.Pose> poses;
    try {
      poses = await det.processImage(input);
    } catch (e) {
      debugPrint('coach pose: $e');
      return;
    }
    if (_closed) return;
    // Landmark space: Android reports in the rotated (upright) image, iOS in
    // the image as delivered.
    final swap = Platform.isAndroid &&
        (rotation == mlkit.InputImageRotation.rotation90deg || rotation == mlkit.InputImageRotation.rotation270deg);
    final w = (swap ? img.height : img.width).toDouble();
    final h = (swap ? img.width : img.height).toDouble();
    _mirrored = rotation == mlkit.InputImageRotation.rotation270deg ||
        ((rotation == mlkit.InputImageRotation.rotation0deg || rotation == mlkit.InputImageRotation.rotation180deg) &&
            cam.lensDirection == CameraLensDirection.front);
    final joints = <Joint, Landmark>{};
    if (poses.isNotEmpty) {
      final lm = poses.first.landmarks;
      _map.forEach((type, j) {
        final l = lm[type];
        if (l != null) joints[j] = Landmark(l.x, l.y, l.likelihood);
      });
    }
    _out.add(PoseFrame(tMs: _clock.elapsedMilliseconds, joints: joints, width: w, height: h, luma: luma));
  }

  static const _map = {
    mlkit.PoseLandmarkType.nose: Joint.nose,
    mlkit.PoseLandmarkType.leftShoulder: Joint.leftShoulder,
    mlkit.PoseLandmarkType.rightShoulder: Joint.rightShoulder,
    mlkit.PoseLandmarkType.leftElbow: Joint.leftElbow,
    mlkit.PoseLandmarkType.rightElbow: Joint.rightElbow,
    mlkit.PoseLandmarkType.leftWrist: Joint.leftWrist,
    mlkit.PoseLandmarkType.rightWrist: Joint.rightWrist,
    mlkit.PoseLandmarkType.leftHip: Joint.leftHip,
    mlkit.PoseLandmarkType.rightHip: Joint.rightHip,
    mlkit.PoseLandmarkType.leftKnee: Joint.leftKnee,
    mlkit.PoseLandmarkType.rightKnee: Joint.rightKnee,
    mlkit.PoseLandmarkType.leftAnkle: Joint.leftAnkle,
    mlkit.PoseLandmarkType.rightAnkle: Joint.rightAnkle,
  };

  static const _deviceDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static mlkit.InputImageRotation _rotation(CameraDescription cam, CameraController ctrl) {
    final sensor = cam.sensorOrientation;
    if (Platform.isIOS) {
      return mlkit.InputImageRotationValue.fromRawValue(sensor) ?? mlkit.InputImageRotation.rotation0deg;
    }
    final device = _deviceDegrees[ctrl.value.deviceOrientation] ?? 0;
    final comp = cam.lensDirection == CameraLensDirection.front ? (sensor + device) % 360 : (sensor - device + 360) % 360;
    return mlkit.InputImageRotationValue.fromRawValue(comp) ?? mlkit.InputImageRotation.rotation0deg;
  }

  static mlkit.InputImage? _inputImage(CameraImage img, mlkit.InputImageRotation rotation) {
    final size = Size(img.width.toDouble(), img.height.toDouble());
    if (Platform.isAndroid) {
      Uint8List bytes;
      int bytesPerRow;
      if (img.planes.length == 1) {
        bytes = img.planes.first.bytes;
        bytesPerRow = img.planes.first.bytesPerRow;
      } else if (img.planes.length == 3) {
        bytes = _yuv420ToNv21(img); // some devices still deliver 3 planes
        bytesPerRow = img.width;
      } else {
        return null;
      }
      return mlkit.InputImage.fromBytes(
        bytes: bytes,
        metadata: mlkit.InputImageMetadata(
            size: size, rotation: rotation, format: mlkit.InputImageFormat.nv21, bytesPerRow: bytesPerRow),
      );
    }
    final format = mlkit.InputImageFormatValue.fromRawValue(img.format.raw as int? ?? -1);
    if (format != mlkit.InputImageFormat.bgra8888 || img.planes.length != 1) return null;
    final p = img.planes.first;
    return mlkit.InputImage.fromBytes(
      bytes: p.bytes,
      metadata: mlkit.InputImageMetadata(size: size, rotation: rotation, format: format!, bytesPerRow: p.bytesPerRow),
    );
  }

  /// YUV_420_888 (3 planes, possibly with row / pixel strides) → NV21.
  static Uint8List _yuv420ToNv21(CameraImage img) {
    final w = img.width, h = img.height;
    final out = Uint8List(w * h + 2 * ((w + 1) ~/ 2) * ((h + 1) ~/ 2));
    final y = img.planes[0], u = img.planes[1], v = img.planes[2];
    var o = 0;
    for (var r = 0; r < h; r++) {
      out.setRange(o, o + w, y.bytes, r * y.bytesPerRow);
      o += w;
    }
    final ps = u.bytesPerPixel ?? 1;
    for (var r = 0; r < h ~/ 2; r++) {
      for (var c = 0; c < w ~/ 2; c++) {
        final i = r * u.bytesPerRow + c * ps;
        if (i >= v.bytes.length || i >= u.bytes.length || o + 1 >= out.length) break;
        out[o++] = v.bytes[i];
        out[o++] = u.bytes[i];
      }
    }
    return out;
  }

  /// Mean brightness from a sparse sample of the frame (for the 「光线太暗」
  /// hint).
  static double? _luma(CameraImage img) {
    if (img.planes.isEmpty) return null;
    final b = img.planes.first.bytes;
    if (b.isEmpty) return null;
    var sum = 0, n = 0;
    if (Platform.isIOS) {
      // BGRA: average of B, G, R of every ~200th pixel.
      for (var i = 0; i + 2 < b.length; i += 4 * 199) {
        sum += (b[i] + b[i + 1] + b[i + 2]) ~/ 3;
        n++;
      }
    } else {
      // NV21 / YUV: the first width × height bytes are the Y (luma) plane.
      final end = img.planes.length == 1 ? (img.width * img.height).clamp(0, b.length) : b.length;
      for (var i = 0; i < end; i += 197) {
        sum += b[i];
        n++;
      }
    }
    return n == 0 ? null : sum / n;
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    final ctrl = _ctrl;
    _ctrl = null;
    try {
      if (ctrl != null && ctrl.value.isStreamingImages) await ctrl.stopImageStream();
    } catch (_) {}
    try {
      await ctrl?.dispose();
    } catch (_) {}
    try {
      await _detector?.close();
    } catch (_) {}
    _detector = null;
    await _out.close();
  }
}
