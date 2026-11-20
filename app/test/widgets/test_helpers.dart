import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:loopland/core/theme.dart';

/// Loads a CJK font and the Material icon font so screenshots are readable
/// (widget tests otherwise render every glyph as a box).
Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
  }

  for (final fam in ['Roboto', 'PingFang SC', 'Noto Sans SC', 'sans-serif']) {
    await load(fam, '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc');
  }
  final root = Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter';
  await load('MaterialIcons', '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Widget wrap(Widget child, {List<Override> overrides = const []}) => ProviderScope(
      overrides: overrides,
      retry: (_, _) => null,
      child: MaterialApp(theme: buildTheme(), home: child, debugShowCheckedModeBanner: false),
    );

/// Phone-sized surface.
Future<void> phone(WidgetTester t, {Size size = const Size(390, 844)}) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

/// Saves the current frame of [finder] as a PNG (for app/screenshots/).
Future<void> screenshot(WidgetTester t, Finder finder, String path) async {
  if (Platform.environment['LOOPLAND_SCREENSHOTS'] != '1') return;
  await t.runAsync(() async {
    final ro = t.renderObject<RenderRepaintBoundary>(finder);
    final img = await ro.toImage(pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File(path)..createSync(recursive: true);
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Unmounts the tree and flushes zero-length timers (Riverpod disposal,
/// fake HTTP futures) so the test binding sees no pending timers.
Future<void> settle(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(milliseconds: 10));
  await t.pump(const Duration(milliseconds: 10));
}

/// Lets real async work (the fake HTTP adapter's streams) complete, then
/// rebuilds.
Future<void> idle(WidgetTester t, [int rounds = 3]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await t.pump(const Duration(milliseconds: 50));
  }
}
