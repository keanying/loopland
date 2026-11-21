// 场馆据点 markers (C-08): a round pin with the 馆主's avatar (or initial),
// a ring in the venue colour and a「馆主 夜跑兔」pill. Shared by the
// fallback painter and the AMap marker bitmaps.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:material_ui/material_ui.dart';

import '../api/local_models.dart';
import '../core/env.dart';
import '../core/theme.dart';
import '../widgets/monster_art.dart' show paintPill;

const _ringColors = [LL.lavender, LL.pink, LL.sky, LL.lime, LL.orange, LL.yellow];
Color venueRingColor(int id) => _ringColors[id.abs() % _ringColors.length];

/// Owner avatars as decoded images, for canvas drawing. Loads lazily and
/// notifies listeners when an image arrives (the fallback map repaints).
class VenueAvatars extends ChangeNotifier {
  VenueAvatars._();
  static final instance = VenueAvatars._();

  /// Tests switch network loading off.
  static bool enabled = true;

  final _images = <String, ui.Image?>{};
  final _loading = <String, Future<ui.Image?>>{};

  static String _abs(String url) => url.startsWith('/') ? '${Env.apiBase}$url' : url;

  /// The decoded image, or null while loading / on failure (starts a load).
  ui.Image? peek(String? url) {
    if (url == null || url.isEmpty || !enabled) return null;
    if (_images.containsKey(url)) return _images[url];
    load(url).then((_) => notifyListeners()).ignore();
    return null;
  }

  Future<ui.Image?> load(String url) {
    if (!enabled) return Future.value();
    if (_images.containsKey(url)) return Future.value(_images[url]);
    return _loading[url] ??= () async {
      final c = Completer<ui.Image?>();
      final stream = NetworkImage(_abs(url)).resolve(ImageConfiguration.empty);
      late final ImageStreamListener l;
      l = ImageStreamListener((info, _) {
        if (!c.isCompleted) c.complete(info.image.clone());
        stream.removeListener(l);
      }, onError: (_, _) {
        if (!c.isCompleted) c.complete(null);
        stream.removeListener(l);
      });
      stream.addListener(l);
      final img = await c.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
      _images[url] = img;
      _loading.remove(url);
      return img;
    }();
  }
}

/// Pin of radius [r] centred on [c]; [avatar] drawn clipped when loaded.
void paintVenueMarker(Canvas canvas, Offset c, MapVenue v, {ui.Image? avatar, double r = 17, bool label = true}) {
  final ring = venueRingColor(v.id);
  canvas.drawCircle(c + const Offset(0, 2), r + 3, Paint()..color = const Color(0x66000000));
  canvas.drawCircle(c, r + 3, Paint()..color = v.hasOwner ? LL.yellow : ring);
  canvas.drawCircle(c, r, Paint()..color = LL.card);
  if (avatar != null) {
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r - 1)));
    paintImage(canvas: canvas, rect: Rect.fromCircle(center: c, radius: r - 1), image: avatar, fit: BoxFit.cover);
    canvas.restore();
  } else {
    final name = v.ownerNickname ?? v.name;
    final ch = name.isEmpty ? '馆' : String.fromCharCodes(name.runes.take(1));
    canvas.drawCircle(c, r - 1, Paint()..color = v.hasOwner ? ring : LL.card2);
    final tp = TextPainter(
      text: TextSpan(
        text: v.hasOwner ? ch : '馆',
        style: TextStyle(
            color: v.hasOwner ? LL.ink : ring,
            fontSize: r * 0.95,
            fontWeight: FontWeight.w900,
            fontFamily: 'Roboto',
            fontFamilyFallback: LL.fonts),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }
  if (v.hasOwner) {
    // Crown dot on top.
    final top = c + Offset(0, -r - 4);
    final crown = Path()
      ..moveTo(top.dx - 7, top.dy + 3)
      ..lineTo(top.dx - 7, top.dy - 4)
      ..lineTo(top.dx - 3.5, top.dy - 0.5)
      ..lineTo(top.dx, top.dy - 6)
      ..lineTo(top.dx + 3.5, top.dy - 0.5)
      ..lineTo(top.dx + 7, top.dy - 4)
      ..lineTo(top.dx + 7, top.dy + 3)
      ..close();
    canvas.drawPath(crown, Paint()..color = LL.yellow);
  }
  if (label) {
    paintPill(canvas, c + Offset(0, r + 16), v.hasOwner ? '馆主 ${v.ownerNickname ?? ''}'.trim() : '暂无馆主', v.hasOwner ? LL.yellow : ring,
        fontSize: 10);
  }
}

/// PNG bytes for an AMap marker (avatar included when [avatar] is set).
Future<Uint8List> venueMarkerBitmap(MapVenue v, ui.Image? avatar) async {
  const ratio = 3.0;
  const size = Size(110, 84);
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(ratio);
  paintVenueMarker(canvas, const Offset(55, 30), v, avatar: avatar);
  final img = await rec.endRecording().toImage((size.width * ratio).ceil(), (size.height * ratio).ceil());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
