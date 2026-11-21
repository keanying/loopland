import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// A picked photo, already compressed by the picker.
typedef PickedImage = ({Uint8List bytes, String name});

/// Picks photos from the gallery. Overridden in tests.
abstract class MediaPicker {
  /// Up to [max] photos (multi-select).
  Future<List<PickedImage>> pickImages(int max);

  /// One photo (avatar).
  Future<PickedImage?> pickOne();
}

class SystemMediaPicker implements MediaPicker {
  final _p = ImagePicker();

  Future<PickedImage> _read(XFile f) async => (bytes: await f.readAsBytes(), name: f.name);

  @override
  Future<List<PickedImage>> pickImages(int max) async {
    if (max <= 0) return const [];
    final files = max == 1
        ? [?await _p.pickImage(source: ImageSource.gallery, maxWidth: 2160, maxHeight: 2160, imageQuality: 85)]
        : await _p.pickMultiImage(limit: max, maxWidth: 2160, maxHeight: 2160, imageQuality: 85);
    return [for (final f in files.take(max)) await _read(f)];
  }

  @override
  Future<PickedImage?> pickOne() async {
    final f = await _p.pickImage(source: ImageSource.gallery, maxWidth: 1080, maxHeight: 1080, imageQuality: 88);
    return f == null ? null : _read(f);
  }
}

final mediaPickerProvider = Provider<MediaPicker>((ref) => SystemMediaPicker());
