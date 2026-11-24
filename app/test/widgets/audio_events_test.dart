// Which sounds the app asks for at key moments (no real audio: the engine
// runs on a RecordingAudioBackend).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/audio/audio.dart';
import 'package:loopland/audio/recording_backend.dart';
import 'package:loopland/audio/run_sounds.dart';
import 'package:loopland/audio/settlement_sounds.dart';
import 'package:loopland/claim/claim.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/me/sound_settings.dart';
import 'package:loopland/features/run/run_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/run/location_source.dart';
import 'package:loopland/run/run_controller.dart';
import 'package:loopland/widgets/nav_shell.dart';
import 'package:loopland/widgets/toast.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'fake_backend.dart';
import 'nav_shell_test.dart' show frames;
import 'test_helpers.dart';

Fix fixAt(double x, double y, int sec, {double accuracy = 5}) {
  final ll = Projection(origin).inverse(Point(x, y));
  return Fix(time: DateTime.utc(2026, 11, 20, 12).add(Duration(seconds: sec)), lat: ll.lat, lng: ll.lng, accuracy: accuracy);
}

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  late RecordingAudioBackend backend;
  late AudioEngine engine;
  // Made inside each test body: the engine's futures must live in the test's
  // (fake-async) zone.
  var now = DateTime.utc(2026, 11, 20, 12);
  void makeEngine() {
    now = DateTime.utc(2026, 11, 20, 12);
    backend = RecordingAudioBackend();
    engine = AudioEngine(backend: backend, clock: () => now);
    addTearDown(engine.dispose);
  }

  testWidgets('run: 3-2-1, go, closing hint, claim (then combo), pause / resume, hold to finish', (t) async {
    await phone(t);
    makeEngine();
    final container = ProviderContainer(
      overrides: [
        ...fakeBackend(extra: {'/v1/map/objects': <String, dynamic>{}}),
        clockProvider.overrideWithValue(() => now),
        locationSourceProvider.overrideWithValue(FakeLocationSource()),
        audioProvider.overrideWithValue(engine),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final ctrl = container.read(runControllerProvider.notifier);
    ctrl.start(const RunConfig(sport: 'run'));
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: buildTheme(), home: const RunPage(), debugShowCheckedModeBanner: false),
    ));
    await t.pump();
    expect(backend.voices, ['run_count_3']);
    expect(backend.shorts, ['run_tick']);
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(backend.voices, ['run_count_3', 'run_count_2', 'run_count_1', 'run_go']);
    expect(backend.shorts, ['run_tick', 'run_tick', 'run_tick', 'run_go']);

    // A square loop: the closing hint counts down, then the loop closes.
    backend.clear();
    final pts = [
      [-150.0, -150.0], [150.0, -150.0], [150.0, 100.0], [0.0, 100.0], [0.0, -250.0], // loop 1
    ];
    for (final (i, p) in pts.indexed) {
      now = now.add(const Duration(seconds: 10));
      ctrl.onFix(fixAt(p[0], p[1], 10 + i * 10));
      await t.pump();
    }
    expect(container.read(runControllerProvider).loops, hasLength(1));
    expect(backend.played('claim'), isTrue, reason: '${backend.log}');
    expect(backend.voices.where((v) => v.startsWith('run_claim_')), hasLength(1));
    expect(backend.haptics, contains('medium'));

    // Second loop → 「连圈！」 (claims share one kind, so wait out the 20 s).
    backend.clear();
    now = now.add(const Duration(seconds: 25));
    for (final (i, p) in [[-200.0, -250.0], [-200.0, 0.0], [-60.0, 0.0], [-60.0, -300.0]].indexed) {
      now = now.add(const Duration(seconds: 5));
      ctrl.onFix(fixAt(p[0], p[1], 100 + i * 10));
      await t.pump();
    }
    expect(container.read(runControllerProvider).loops.length, greaterThanOrEqualTo(2));
    expect(backend.voices, contains('run_claim_combo'));

    backend.clear();
    ctrl.pause();
    await t.pump();
    ctrl.resume();
    await t.pump();
    expect(backend.voices, ['run_pause', 'run_resume']);

    // Hold the finish button: loop while holding, released early → stop.
    backend.clear();
    final g = await t.startGesture(t.getCenter(find.byType(LongPressButton)));
    await t.pump(const Duration(milliseconds: 300));
    expect(backend.log.where((l) => l.startsWith('loop:')).single, endsWith('run_hold.m4a'));
    await g.up();
    await t.pump();
    expect(backend.log.last, 'loop_stop');
    expect(backend.shorts, isEmpty);

    ctrl.reset();
    await t.pump();
    await settle(t);
  });

  test('run sounds: hints once per approach, km lines, GPS weak / back, boss near / hit, goal', () async {
    makeEngine();
    final base = RunState(phase: RunPhase.running, startedAt: now, resumedAt: now, goal: const Goal(type: 'distance', value: 2000));
    final rs = RunSounds(engine, base, now);
    var s = base;
    Future<void> step(RunState n, {int sec = 1, MapObjects o = const MapObjects()}) async {
      now = now.add(Duration(seconds: sec));
      rs.onState(s, n, now, nearby: o);
      s = n;
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    RunState at(double d, {double? hint, Fix? fix}) => s.copyWith(
          distanceM: d,
          hint: () => hint == null ? null : ClosingHint(hint, origin),
          lastFix: fix ?? Fix(time: now, lat: origin.lat, lng: origin.lng, accuracy: 5),
        );

    await step(at(300, hint: 260));
    await step(at(350, hint: 190));
    await step(at(360, hint: 180));
    await step(at(420, hint: 95), sec: 25);
    await step(at(450, hint: 45), sec: 25);
    expect(backend.voices, ['run_close_200', 'run_close_100', 'run_close_50']);

    backend.clear();
    await step(at(1010), sec: 300);
    expect(backend.spoken.single, startsWith('第 1 公里，用时 '));
    expect(backend.voices, ['run_half']);

    // No usable fix for > 30 s → weak; a good one → back.
    backend.clear();
    final bad = Fix(time: now, lat: origin.lat, lng: origin.lng, accuracy: 80);
    await step(at(1020, fix: bad), sec: 10);
    await step(s.copyWith(tick: 1), sec: 25);
    expect(backend.voices, ['run_gps_weak']);
    await step(at(1030));
    expect(backend.voices, ['run_gps_weak', 'run_gps_back']);

    // Boss: near (outside its range), then inside → hit, once per run.
    backend.clear();
    final boss = MapObjects(bosses: [
      MapBoss(id: 7, kind: 'bat', name: '熬夜蝠', center: Projection(origin).inverse(const Point(0, 1200)), radiusM: 1000),
    ]);
    await step(at(1100), o: boss);
    expect(backend.voices, ['run_boss_near']);
    expect(backend.shorts.single, startsWith('boss_bat_tap_'));
    final inside = Projection(origin).inverse(const Point(0, 600));
    await step(at(1200, fix: Fix(time: now, lat: inside.lat, lng: inside.lng, accuracy: 5)), o: boss, sec: 30);
    await step(at(1300, fix: Fix(time: now, lat: inside.lat, lng: inside.lng, accuracy: 5)), o: boss, sec: 30);
    expect(backend.voices.where((v) => v == 'run_boss_hit'), hasLength(1));
    expect(backend.played('boss_hit'), isTrue);
    expect(backend.played('boss_bat_hit'), isTrue);

    backend.clear();
    await step(at(2000), sec: 300);
    expect(backend.voices, contains('run_goal'));
    expect(backend.spoken.single, startsWith('第 2 公里'));
  });

  test('settlement: effects and voice lines from the result', () {
    final r = ActivityResult.fromJson({
      'activity': {'id': 1, 'sport': 'run', 'distance_m': 5200, 'duration_s': 1860},
      'settlement': {
        'status': 'settled',
        'energy_granted': 30,
        'energy_capped': true,
        'claims': [
          {'territory_id': 1, 'kind': 'claim', 'area_m2': 900},
          {'territory_id': 2, 'kind': 'capture', 'area_m2': 700},
        ],
        'boss_damage': [
          {'boss_id': 3, 'name': '糖分怪', 'damage': 120, 'defeated': true},
        ],
        'level_up': {'from': 3, 'to': 4},
      },
    });
    final p = SettlementPlan(r);
    expect(p.effects.map((e) => e.$1.id), ['claim', 'boss_down', 'boss_sugar_down', 'energy_gain', 'level_up']);
    expect(p.voice.map((v) => '$v'), [
      'tts(本次 5.2 公里，用时 31 分钟，圈下 2 块地)',
      'clip(run_steal)',
      'clip(run_boss_down)',
      'clip(result_levelup)',
    ]);
    final review = SettlementPlan(ActivityResult.fromJson({
      'activity': {'id': 1, 'sport': 'run'},
      'settlement': {'status': 'review'},
    }));
    expect(review.voice.map((v) => '$v'), ['clip(result_review)']);
    expect(review.effects, isEmpty);
  });

  testWidgets('bottom bar: tab switch → ui_tab, 开始 → start_press, again → the companion', (t) async {
    await phone(t);
    makeEngine();
    final router = GoRouter(initialLocation: '/map', routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => NavShell(shell: shell),
        branches: [
          for (final path in ['/map', '/codex', '/start', '/community', '/me'])
            StatefulShellBranch(routes: [GoRoute(path: path, builder: (_, _) => Center(child: Text(path)))]),
        ],
      ),
    ]);
    await t.pumpWidget(ProviderScope(
      overrides: [
        codexProvider.overrideWith((ref) async => Codex.fromJson(j(codexJson))),
        audioProvider.overrideWithValue(engine),
      ],
      retry: (_, _) => null,
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router),
    ));
    await frames(t);
    await t.tap(find.bySemanticsLabel('图鉴'));
    await frames(t);
    expect(find.text('/codex'), findsOneWidget);
    expect(backend.shorts.single, startsWith('ui_tab_'));
    await t.tap(find.bySemanticsLabel('图鉴')); // same tab: no sound
    await frames(t);
    expect(backend.shorts, hasLength(1));

    backend.clear();
    await t.tap(find.bySemanticsLabel('开始'));
    await frames(t);
    expect(backend.shorts, ['start_press']);
    expect(backend.haptics, ['light']);
    await t.tap(find.bySemanticsLabel('开始'));
    await frames(t);
    expect(backend.shorts.last, matches(RegExp(r'^pet_\w+_tap_\d$')));
    await settle(t);
  });

  testWidgets('设置 → 声音: switches, volume and 试听 are saved', (t) async {
    await phone(t);
    makeEngine();
    final kv = MemoryCache();
    final e = AudioEngine(backend: backend, kv: kv);
    addTearDown(e.dispose);
    await t.pumpWidget(wrap(const Material(child: SoundSettings()), overrides: [audioProvider.overrideWithValue(e)]));
    await t.pump();
    expect(find.text('语音播报'), findsOneWidget);
    expect(find.text('音效'), findsOneWidget);
    expect(find.text('角色声音'), findsOneWidget);

    await t.tap(find.bySemanticsLabel('试听音效'));
    await t.pump();
    expect(backend.played('claim'), isTrue);

    await t.tap(find.byType(Switch).at(2)); // 角色声音 off
    await t.pump();
    expect(e.isEnabled(SoundChannel.character), isFalse);
    expect(backend.shorts.last, 'ui_toggle_off');
    expect(await kv.read('audio_settings'), contains('"character":{"on":false'));
    await settle(t);
  });

  testWidgets('toasts: success / error make a sound, info / warning stay quiet', (t) async {
    makeEngine();
    await t.pumpWidget(wrap(
      Builder(
        builder: (context) => Column(children: [
          for (final k in ToastKind.values)
            TextButton(onPressed: () => toast(context, k.name, kind: k), child: Text('toast ${k.name}')),
        ]),
      ),
      overrides: [audioProvider.overrideWithValue(engine)],
    ));
    for (final k in ToastKind.values) {
      await t.tap(find.text('toast ${k.name}'));
      await t.pump();
    }
    expect(backend.shorts, ['ui_success', 'ui_error']);
    dismissToast();
    await settle(t);
  });

  testWidgets('result page sounds: first effect at once, the rest staggered, voice queued', (t) async {
    makeEngine();
    final r = ActivityResult.fromJson({
      'activity': {'id': 1, 'sport': 'run', 'distance_m': 3000, 'duration_s': 1200},
      'settlement': {
        'status': 'settled',
        'energy_granted': 20,
        'claims': [
          {'territory_id': 1, 'kind': 'claim', 'area_m2': 900},
        ],
        'chests': [
          {'chest_id': 4, 'energy': 10},
        ],
      },
    });
    await t.pumpWidget(wrap(SettlementSounds(result: r, child: const SizedBox()), overrides: [audioProvider.overrideWithValue(engine)]));
    await t.pump();
    expect(backend.shorts.single, startsWith('claim_'));
    expect(backend.spoken, ['本次 3.0 公里，用时 20 分钟，圈下 1 块地']);
    await t.pump(const Duration(milliseconds: 700));
    await t.pump(const Duration(milliseconds: 700));
    expect(backend.shorts.skip(1).map((e) => e.replaceAll(RegExp(r'_\d$'), '')), ['chest_open', 'energy_gain']);
    await settle(t);
  });
}
