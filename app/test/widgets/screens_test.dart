// Smoke tests that render the main screens against canned data and, with
// LOOPLAND_SCREENSHOTS=1, write PNGs to app/screenshots/.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/features/city/city_page.dart';
import 'package:loopland/features/map/map_page.dart';
import 'package:loopland/features/run/run_page.dart';
import 'package:loopland/features/start/start_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_backend.dart';
import 'test_helpers.dart';

Fix fixAt(double x, double y, int sec) {
  final ll = Projection(origin).inverse(Point(x, y));
  return Fix(time: DateTime.utc(2026, 11, 20, 12).add(Duration(seconds: sec)), lat: ll.lat, lng: ll.lng, accuracy: 5);
}

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  testWidgets('领地 map home renders territories and opens the sheet', (t) async {
    await phone(t);
    final loc = FakeLocationSource([fixAt(-40, -60, 0)]);
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const MapPage(), overrides: [...fakeBackend(), locationSourceProvider.overrideWithValue(loc)]),
    ));
    await t.pump();
    // locate → move → bounds debounce → load
    for (var i = 0; i < 3; i++) {
      await idle(t, 1);
      await t.pump(const Duration(milliseconds: 400));
    }
    await idle(t);
    expect(find.text('嗨，阿杰'), findsOneWidget);
    expect(find.text('全城'), findsOneWidget);
    expect(find.text('建城'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/map.png');

    // Tap the centre of the map: 滨江公园 (mine) lies under the initial centre.
    await t.tapAt(const Offset(195, 422 + 30));
    await t.pump(const Duration(milliseconds: 400)); // double-tap (zoom) window
    await t.pumpAndSettle();
    expect(find.text('滨江公园'), findsOneWidget);
    expect(find.text('去建设'), findsOneWidget);
    await settle(t);
  });

  testWidgets('hit testing picks the smallest territory under the point', (t) async {
    final ts = sampleTerritories.map(TerritorySummary.fromJson).toList();
    final p = Projection(origin).inverse(const Point(0, -120));
    expect(hitTest(ts, p)!.name, '滨江公园');
    expect(hitTest(ts, Projection(origin).inverse(const Point(2000, 2000))), isNull);
    await settle(t);
  });

  testWidgets('running screen: live stats, loop preview and close hint', (t) async {
    await phone(t);
    var now = DateTime.utc(2026, 11, 20, 12);
    final container = ProviderContainer(
      overrides: [
        ...fakeBackend(),
        clockProvider.overrideWithValue(() => now),
        locationSourceProvider.overrideWithValue(FakeLocationSource()),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final ctrl = container.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'run'), countdownFrom: 0);
    final pts = [
      [-150.0, -150.0], [150.0, -150.0], [150.0, 100.0], [0.0, 100.0], [0.0, -250.0], // loop 1
      [-200.0, -250.0], [-200.0, 0.0], [-60.0, 0.0],
    ];
    for (final (i, p) in pts.indexed) {
      ctrl.onFix(fixAt(p[0], p[1], i * 40));
    }
    now = now.add(const Duration(minutes: 6, seconds: 12));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: buildTheme(), home: const RunPage(), debugShowCheckedModeBanner: false),
      ),
    ));
    await t.pump();
    await t.pump();
    expect(find.text('已圈 1 块'), findsOneWidget);
    expect(find.textContaining('米可闭合'), findsOneWidget);
    expect(find.text('长按结束'), findsOneWidget);
    expect(find.text('06:12'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/run.png');

    ctrl.pause();
    await t.pump();
    expect(find.text('继续'), findsOneWidget);
    ctrl.reset();
    await t.pump();
    await settle(t);
  });

  testWidgets('建城 page shows slots, stats and stationed roles', (t) async {
    await phone(t, size: const Size(390, 1100));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const CityPage(territoryId: 101), overrides: fakeBackend()),
    ));
    await idle(t);
    expect(find.text('守卫值'), findsOneWidget);
    expect(find.text('+25'), findsOneWidget);
    expect(find.text('建造'), findsNWidgets(5));
    expect(find.text('领地守卫 +5%'), findsOneWidget);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/city.png');
    await settle(t);
  });

  testWidgets('开始 page lists GPS / venue (V2) / home sports', (t) async {
    await phone(t, size: const Size(390, 1100));
    await t.pumpWidget(RepaintBoundary(key: const Key('shot'), child: wrap(const StartPage(), overrides: fakeBackend())));
    await idle(t);
    expect(find.text('开始跑步'), findsOneWidget);
    expect(find.text('招募 弓箭手'), findsOneWidget);
    expect(find.text('10 能量 / km'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/start.png');
    await t.tap(find.text('场馆球类'));
    await t.pump();
    expect(find.text('即将开放'), findsOneWidget);
    await t.tap(find.text('居家跟练'));
    await t.pump();
    expect(find.text('开始训练'), findsOneWidget);
    await settle(t);
  });
}
