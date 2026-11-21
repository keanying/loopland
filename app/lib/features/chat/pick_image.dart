import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// An image chosen from the gallery / camera.
typedef PickedImage = ({Uint8List bytes, String name});

/// Picks one image (chat, crew avatar). Overridden in tests.
final singleImagePickerProvider = Provider<Future<PickedImage?> Function({bool camera})>((ref) => ({bool camera = false}) async {
      final x = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (x == null) return null;
      return (bytes: await x.readAsBytes(), name: x.name);
    });
