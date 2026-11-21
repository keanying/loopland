// AI 跟练 (C-09) screens with a fake pose source: catalog, the guided session
// (camera counting, rest, manual fallback, voice cues), upload with `coach`,
// settlement. LOOPLAND_SCREENSHOTS=1 writes screenshots/v2/ai_coach_*.png.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loopland/coach/pose.dart';
import 'package:loopland/coach/pose_source.dart';
import 'package:loopland/coach/voice.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/coach/coach_routes.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/features/start/start_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:loopland/run/run_controller.dart' show clockProvider;
import 'package:loopland/run/run_store.dart';
import 'package:loopland/run/uploader.dart';
import 'package:material_ui/material_ui.dart';

import '../coach/synthetic.dart';
import 'coach_fake.dart';
import 'fake_backend.dart';
import 'test_helpers.dart';

/// Pending uploads in memory (no file IO inside the fake-async test zone).
class _MemRunStore extends RunStore {
  final _m = <String, PendingUpload>{};
  @override
  Future<void> savePending(PendingUpload p) async => _m[p.upload.clientId] = p;
  @override
  Future<List<PendingUpload>> pending() async => _m.values.toList();
  @override
  Future<void> removePending(String clientId) async => _m.remove(clientId);
}

class _Stub extends StatelessWidget {
  const _Stub(this.loc);
  final String loc;
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Text('STUB $loc')));
}

late DateTime now;
late CoachFake fake;
late RecordingVoiceCoach voice;
late List<FakePoseSource> sources;

Widget app(String initial, {PoseSourceStatus camera = PoseSourceStatus.ready, bool preview = false}) {
  final router = GoRouter(initialLocation: initial, routes: [
    GoRoute(path: '/start', builder: (_, _) => const StartPage()),
    ...coachRoutes(),
    GoRoute(
      path: '/result',
      builder: (_, s) => ResultPage(args: s.extra! as ResultArgs),
    ),
    for (final p in ['/me', '/train/:sport']) GoRoute(path: p, builder: (_, s) => _Stub(s.uri.toString())),
  ]);
  final overrides = <Override>[
    ...fakeBackend(handlers: [fake.handle]),
    clockProvider.overrideWithValue(() => now),
    voiceCoachProvider.overrideWithValue(voice),
    poseSourceFactoryProvider.overrideWithValue(() {
      final s = FakePoseSource(status: camera, preview: preview);
      sources.add(s);
      return s;
    }),
    runStoreProvider.overrideWithValue(_MemRunStore()),
  ];
  return RepaintBoundary(
    key: const Key('shot'),
    child: ProviderScope(
      overrides: overrides,
      retry: (_, _) => null,
      child: MaterialApp.router(theme: buildTheme(), routerConfig: router, debugShowCheckedModeBanner: false),
    ),
  );
}

/// Advances the fake clock together with the widget clock.
Future<void> wait(WidgetTester t, int ms) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    now = now.add(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Feeds [seconds] of rope skipping (2 Hz) at 15 fps from the fake camera.
Future<void> skip(WidgetTester t, FakePoseSource src, double seconds, {int t0 = 0, double amp = 0.09}) async {
  for (final ms in times(seconds, 15)) {
    now = now.add(const Duration(milliseconds: 66));
    src.emit(standing(t0 + ms, liftPx: amp * torsoPx * math.max(0, math.sin(2 * math.pi * 2 * ms / 1000))));
    await t.pump(const Duration(milliseconds: 66));
  }
}

/// [seconds] of frames where nobody is detected (dark room / left).
Future<void> empty(WidgetTester t, FakePoseSource src, double seconds, {int t0 = 0}) async {
  for (final ms in times(seconds, 15)) {
    now = now.add(const Duration(milliseconds: 66));
    src.emit(PoseFrame(tMs: t0 + ms, joints: const {}, luma: 20));
    await t.pump(const Duration(milliseconds: 66));
  }
}

Future<void> shot(WidgetTester t, String name) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await t.pump();
  await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/$name.png');
}

String text(WidgetTester t, String key) => (t.widget(find.byKey(Key(key))) as Text).data!;

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  setUp(() {
    now = DateTime.utc(2026, 11, 21, 12);
    fake = CoachFake();
    voice = RecordingVoiceCoach();
    sources = [];
  });

  testWidgets('start page 居家跟练 → AI 跟练; 手动记录 keeps the old page', (t) async {
    await phone(t);
    await t.pumpWidget(app('/start'));
    await idle(t);
    await t.tap(find.text('居家跟练'));
    await t.pumpAndSettle();
    await t.tap(find.text('跳绳'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('手动记录'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('AI 跟练'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/ai_coach_start.png');
    await t.tap(find.text('手动记录'));
    await t.pumpAndSettle();
    expect(find.text('STUB /train/rope'), findsOneWidget);
    await settle(t);
  });

  testWidgets('catalog: tabs by sport, cards, privacy note, 手动记录', (t) async {
    await phone(t);
    await t.pumpWidget(app('/coach?sport=rope'));
    await idle(t);
    expect(find.text('AI 跟练'), findsOneWidget);
    expect(find.text('跳绳'), findsOneWidget);
    expect(find.text('HIIT'), findsOneWidget);
    expect(find.text('跳绳入门'), findsOneWidget);
    expect(find.text('跳绳进阶'), findsOneWidget);
    expect(find.text('双脚跳'), findsNWidgets(2));
    expect(find.text('5 次 × 2 组'), findsOneWidget);
    expect(find.text('摄像头自动计数'), findsNWidgets(2));
    expect(find.textContaining('摄像头画面不上传、不保存'), findsOneWidget);
    expect(find.text('课程库暂时无法更新，先用内置课程'), findsNothing);
    await shot(t, 'ai_coach_catalog');

    await t.tap(find.text('HIIT'));
    await t.pump();
    expect(find.text('HIIT 燃脂'), findsOneWidget);
    expect(find.text('跳绳入门'), findsNothing);

    await t.tap(find.byKey(const Key('coach-manual-entry')));
    await t.pumpAndSettle();
    expect(find.text('STUB /train/hiit'), findsOneWidget);
    await settle(t);
  });

  testWidgets('session: camera counting, rest, manual fallback, voice, upload with coach, settlement', (t) async {
    await phone(t);
    await t.pumpWidget(app('/coach?sport=rope', preview: true));
    await idle(t);
    await t.tap(find.text('开始跟练').first);
    await t.pumpAndSettle();
    await idle(t);

    // Ready: camera on, design hint, set bars, target.
    final src = sources.single;
    expect(src.started, isTrue);
    expect(find.text('摄像头已就绪'), findsOneWidget);
    expect(find.text('把手机立在 2 米外，全身入镜后点开始'), findsOneWidget);
    expect(find.textContaining('画面不上传、不保存'), findsOneWidget);
    expect(text(t, 'coach-big'), '5');
    expect(text(t, 'coach-sets'), '1/2');
    await skip(t, src, 0.5); // standing in front of the camera
    await shot(t, 'ai_coach_ready');

    await t.tap(find.byKey(const Key('coach-main')));
    await t.pump();
    expect(voice.spoken.last, '第一个动作：双脚跳，5 次，共 2 组。准备');
    await wait(t, 5000);
    expect(voice.spoken, containsAllInOrder(['3', '2', '1', '双脚跳，5 次，共 2 组。保持节奏，落地轻一点。开始']));
    expect(find.text('暂停'), findsOneWidget);

    // Partial body → 全身入镜 hint.
    for (var i = 0; i < 12; i++) {
      now = now.add(const Duration(milliseconds: 66));
      final f = standing(i * 66, scale: 1.6); // feet below the picture
      src.emit(f);
      await t.pump(const Duration(milliseconds: 66));
    }
    expect(find.text('未检测到全身'), findsOneWidget);
    expect(find.text('全身入镜：退后一点，让头到脚都进入画面'), findsOneWidget);

    // Skipping in front of the camera: 2 jumps / s.
    await skip(t, src, 1.8, t0: 2000);
    expect(find.textContaining('AI 计数中'), findsOneWidget);
    final mid = int.parse(text(t, 'coach-count'));
    expect(mid, inInclusiveRange(2, 4));
    expect(text(t, 'coach-big'), '$mid/5');
    await shot(t, 'ai_coach_counting');
    await skip(t, src, 2.5, t0: 4000);
    // 5 reps → set done → rest 3 s.
    expect(find.text('休息一下'), findsOneWidget);
    expect(find.text('下一个：双脚跳 · 5 次 · 第 2/2 组'), findsOneWidget);
    expect(voice.spoken, contains('休息 3 秒。准备第 2 组'));
    expect(text(t, 'coach-sets'), '2/2');
    await shot(t, 'ai_coach_rest');
    await t.tap(find.text('跳过休息'));
    await t.pump();
    expect(voice.spoken.last, '第 2 组，开始');

    // Lights go out / nobody seen for > 4 s → manual counting.
    await empty(t, src, 4.5, t0: 8000);
    expect(find.textContaining('已切换为手动计数'), findsOneWidget);
    expect(find.textContaining('点此恢复自动'), findsOneWidget);
    expect(find.byKey(const Key('coach-plus1')), findsOneWidget);
    expect(find.text('个 · 手动计数'), findsOneWidget);
    expect(find.text('光线太暗，已改为手动计数：做完一下点一次 +1'), findsOneWidget);
    await t.pump(const Duration(seconds: 6)); // toast
    now = now.add(const Duration(seconds: 6));
    await shot(t, 'ai_coach_manual');
    // Frames are ignored in manual mode.
    await skip(t, src, 1.5, t0: 13000);
    expect(text(t, 'coach-count'), '0');
    for (var i = 0; i < 4; i++) {
      await t.tap(find.byKey(const Key('coach-plus1')));
      await t.pump();
    }
    expect(text(t, 'coach-count'), '4');
    await t.tap(find.text('-1'));
    await t.pump();
    expect(text(t, 'coach-count'), '3');
    await t.tap(find.text('+10')); // ends the set (≥ target)
    await t.pump();
    expect(find.text('休息一下'), findsOneWidget);
    expect(find.text('下一个：放松拉伸 · 4 秒 · 第 1/1 组'), findsOneWidget);
    expect(voice.spoken.last, '休息 3 秒。下一个：放松拉伸');

    // Mute: no more voice.
    final spoken = voice.spoken.length;
    await t.tap(find.byIcon(Icons.volume_up_rounded));
    await t.pump();
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);

    // Pause / resume during the timed step.
    await wait(t, 3200);
    expect(text(t, 'coach-big'), '00:04');
    await t.tap(find.text('暂停'));
    await t.pump();
    expect(find.text('已暂停，休息一下，准备好再继续'), findsOneWidget);
    await wait(t, 3000);
    expect(text(t, 'coach-big'), '00:04');
    await t.tap(find.text('继续'));
    await t.pump();
    await wait(t, 4200);
    expect(voice.spoken.length, spoken, reason: 'muted');

    // Finished: summary + 领取能量.
    expect(find.byKey(const Key('coach-summary')), findsOneWidget);
    expect(find.text('训练完成！'), findsOneWidget);
    expect(find.text('3/3'), findsWidgets);
    expect(find.text('5 次'), findsOneWidget); // AI 自动计数
    expect(find.text('13 次'), findsOneWidget); // 手动计数
    expect(text(t, 'coach-energy'), '+3'); // 18 次 / 5 × 1
    expect(sources.single.disposed, isTrue, reason: 'camera off once the session is over');
    await shot(t, 'ai_coach_summary');

    await t.tap(find.text('领取能量'));
    await t.pump();
    await idle(t, 6);
    await t.pump(const Duration(milliseconds: 500)); // page transition
    expect(fake.uploads, hasLength(1));
    final u = fake.uploads.single;
    expect(u['sport'], 'rope');
    expect(u['amount'], 18);
    expect(u['coach'], {'workout_key': 'rope_test', 'camera': true, 'reps_detected': 5, 'reps_manual': 13, 'sets_done': 3});
    expect(u['duration_s'], greaterThan(10));
    expect(u.containsKey('points'), isFalse);
    // The existing settlement page.
    expect(find.byType(ResultPage), findsOneWidget);
    expect(find.text('+2'), findsWidgets);
    await shot(t, 'ai_coach_result');
    await settle(t);
  });

  testWidgets('catalog 503 ai_unavailable → built-in courses; no camera → timer + manual count', (t) async {
    fake.catalogAvailable = false;
    await phone(t);
    await t.pumpWidget(app('/coach?sport=strength', camera: PoseSourceStatus.unavailable));
    await idle(t);
    expect(find.text('课程库暂时无法更新，先用内置课程'), findsOneWidget);
    expect(find.text('力量入门'), findsOneWidget);
    expect(find.text('普拉提'), findsOneWidget); // tab
    await t.tap(find.text('开始跟练').first);
    await t.pumpAndSettle();
    await idle(t);
    expect(find.text('没有可用的摄像头 · 手动计数'), findsOneWidget);
    expect(find.text('跟着计时练，做完一下点一次 +1'), findsOneWidget);
    await t.tap(find.byKey(const Key('coach-main')));
    await t.pump();
    await wait(t, 5000);
    expect(find.byKey(const Key('coach-plus1')), findsOneWidget);
    await t.tap(find.byKey(const Key('coach-plus1')));
    await t.pump();
    expect(text(t, 'coach-big'), '1/15');
    await shot(t, 'ai_coach_no_camera');
    // 完成本组 with what was counted → rest 40 s → skip whole step.
    await t.tap(find.text('完成本组'));
    await t.pump();
    expect(find.text('休息一下'), findsOneWidget);
    await t.tap(find.text('结束训练'));
    await t.pump();
    expect(find.text('训练结束').evaluate().isEmpty, isTrue, reason: '1 set done → 训练完成！');
    expect(find.text('训练完成！'), findsOneWidget);
    // strength is settled by minutes: < 1 min → not uploaded.
    await t.tap(find.text('领取能量'));
    await t.pump();
    expect(find.text('至少训练 1 分钟才能换能量'), findsOneWidget);
    expect(fake.uploads, isEmpty);
    await t.pump(const Duration(seconds: 4));
    await settle(t);
  });

  testWidgets('camera permission refused → manual counting with a clear note', (t) async {
    await phone(t);
    await t.pumpWidget(app('/coach/hiit_test', camera: PoseSourceStatus.denied));
    await idle(t);
    expect(find.text('HIIT 燃脂 · 进阶'), findsOneWidget);
    expect(find.text('未获得摄像头权限 · 手动计数'), findsOneWidget);
    expect(find.text('没有摄像头权限也能练：跟着计时，做完一下点一次 +1'), findsOneWidget);
    // Leaving mid-session asks first.
    await t.tap(find.byKey(const Key('coach-main')));
    await t.pump();
    await wait(t, 1000);
    await t.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
    await t.pumpAndSettle();
    expect(find.text('结束训练？'), findsOneWidget);
    await t.tap(find.text('继续训练'));
    await t.pumpAndSettle();
    expect(find.text('暂停'), findsOneWidget);
    await settle(t);
  });
}
