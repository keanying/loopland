import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/audio/audio.dart';
import 'package:loopland/audio/recording_backend.dart';
import 'package:loopland/core/providers.dart';

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late DateTime now;
  late RecordingAudioBackend backend;
  late AudioEngine engine;

  AudioEngine make({RecordingAudioBackend? b, KvCache? kv}) => AudioEngine(
        backend: b ?? backend,
        kv: kv,
        clock: () => now,
        random: math.Random(1),
      );

  setUp(() {
    now = DateTime(2026, 11, 24, 7);
    backend = RecordingAudioBackend(autoComplete: false);
    engine = make();
  });

  tearDown(() => engine.dispose());

  group('catalogue', () {
    test('every catalogued file is bundled, every bundled file is catalogued', () {
      final catalogued = {for (final s in Sounds.all) ...s.assets};
      final onDisk = {
        for (final f in Directory('assets/audio').listSync(recursive: true))
          if (f is File && f.path.endsWith('.m4a')) f.path.replaceAll('\\', '/').substring('assets/'.length),
      };
      expect(onDisk.length, 132);
      expect(catalogued.difference(onDisk), isEmpty, reason: 'catalogued but missing');
      expect(onDisk.difference(catalogued), isEmpty, reason: 'bundled but not catalogued');
    });

    test('pubspec registers every audio folder', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final dirs = {for (final s in Sounds.all) 'assets/audio/${s.dir}/'};
      for (final d in dirs) {
        expect(pubspec, contains('- $d'));
      }
    });

    test('ids, variants and character helpers', () {
      expect(Sounds.runClaim.assets, [for (var i = 1; i <= 3; i++) 'audio/voice/run/run_claim_$i.m4a']);
      expect(Sounds.uiToggleOn.asset(1), 'audio/sfx/ui_toggle_on.m4a');
      expect(Sounds.bossDownChar('bat').asset(1), 'audio/char/boss_bat_down_1.m4a');
      expect(Sounds.bossTap('unknown').id, 'boss_sofa_tap');
      expect(Sounds.role('knight')!.asset(1), 'audio/char/role_knight.m4a');
      expect(Sounds.petTap('dragon'), isNull);
      expect(Sounds.runClaim.textOf(2), '漂亮！又多一块领地。');
      expect(Sounds.runGo.textOf(1), '出发！今天去圈哪块地？');
      expect(Sounds.bossHit.gainDb(1), 3);
      expect(Sounds.role('knight')!.gainDb(1), 4);
      for (final s in Sounds.all.where((s) => s.channel == SoundChannel.voice)) {
        expect(s.textOf(1), isNotEmpty, reason: s.id);
      }
    });
  });

  test('variants are random and never repeat back to back', () async {
    final b = RecordingAudioBackend();
    final e = make(b: b);
    for (var i = 0; i < 40; i++) {
      e.play(Sounds.uiTap);
    }
    await flush();
    final s = b.shorts;
    expect(s.length, 40);
    expect(s.toSet(), {'ui_tap_1', 'ui_tap_2', 'ui_tap_3'});
    for (var i = 1; i < s.length; i++) {
      expect(s[i], isNot(s[i - 1]));
    }
    e.dispose();
  });

  test('quiet files are boosted, the channel volume scales everything', () async {
    final vols = <String, double>{};
    final b = _VolumeBackend(vols);
    final e = AudioEngine(backend: b, random: math.Random(3))..setVolume(SoundChannel.sfx, 0.8);
    for (var i = 0; i < 12; i++) {
      e.play(Sounds.bossHit);
    }
    await flush();
    expect(vols['audio/sfx/boss_hit_1.m4a']! / vols['audio/sfx/boss_hit_2.m4a']!, closeTo(math.pow(10, 3 / 20), 0.01));
    e.setVolume(SoundChannel.sfx, 0.5);
    e.play(Sounds.uiSuccess);
    await flush();
    expect(vols['audio/sfx/ui_success.m4a'], closeTo(0.5 * AudioEngine.shortHeadroom, 1e-9));
    e.dispose();
  });

  group('voice queue', () {
    test('one at a time, highest priority first', () async {
      engine.say(Sounds.runResume); // starts at once
      engine.sayText('第 1 公里', priority: VoicePriority.km, kind: 'km');
      engine.say(Sounds.runClaimCombo, priority: VoicePriority.claim);
      engine.say(Sounds.runGpsWeak, priority: VoicePriority.safety);
      engine.say(Sounds.runChest);
      await flush();
      expect(backend.voices, ['run_resume']);
      expect(engine.queued, 4);
      for (var i = 0; i < 4; i++) {
        backend.finishVoice();
        await flush();
      }
      expect(backend.log.where((l) => l.startsWith('voice:') || l.startsWith('tts:')).map((l) => l.split('/').last), [
        'run_resume.m4a',
        'run_gps_weak.m4a',
        'run_claim_combo.m4a',
        'tts:第 1 公里',
        'run_chest.m4a',
      ]);
      backend.finishVoice();
      await flush();
      // Ducked for the whole burst, once.
      expect(backend.log.where((l) => l.startsWith('duck:')), ['duck:true', 'duck:false']);
      expect(backend.log.first, 'duck:true');
      expect(backend.log.last, 'duck:false');
    });

    test('same kind at least 20 s apart, countdown excepted', () async {
      final b = RecordingAudioBackend();
      final e = make(b: b);
      Future<void> say(Sound s, {VoicePriority p = VoicePriority.other, String? kind}) async {
        e.say(s, priority: p, kind: kind);
        await flush();
      }

      await say(Sounds.runClose100);
      now = now.add(const Duration(seconds: 10));
      await say(Sounds.runClose100); // too soon
      await say(Sounds.runClose50); // another kind
      now = now.add(const Duration(seconds: 11));
      await say(Sounds.runClose100); // 21 s after the first
      for (var i = 0; i < 3; i++) {
        await say(Sounds.runCount(3 - i), p: VoicePriority.countdown);
        await say(Sounds.runCount(3 - i), p: VoicePriority.countdown);
      }
      // Kinds group lines: two different claim lines within 20 s.
      await say(Sounds.runClaim, kind: 'claim', p: VoicePriority.claim);
      await say(Sounds.runClaimCombo, kind: 'claim', p: VoicePriority.claim);
      expect(b.voices.where((v) => v == 'run_close_100'), hasLength(2));
      expect(b.voices, contains('run_close_50'));
      expect(b.voices.where((v) => v.startsWith('run_count_')), hasLength(6));
      expect(b.voices.where((v) => v.startsWith('run_claim')), hasLength(1));
      e.dispose();
    });

    test('stale low-priority items are dropped, a full queue drops the lowest', () async {
      engine.say(Sounds.runResume);
      engine.say(Sounds.runChest); // other: max 8 s
      engine.say(Sounds.runBossNear, priority: VoicePriority.boss); // 15 s
      await flush();
      now = now.add(const Duration(seconds: 10));
      backend.finishVoice();
      await flush();
      backend.finishVoice();
      await flush();
      expect(backend.voices, ['run_resume', 'run_boss_near']);

      backend.finishVoice();
      await flush();
      backend.clear();
      final e = make(b: backend);
      e.say(Sounds.runResume);
      for (final s in [Sounds.runChest, Sounds.runSupply, Sounds.runHalf, Sounds.runGoal]) {
        e.say(s);
      }
      e.say(Sounds.runGpsBack, priority: VoicePriority.safety);
      await flush();
      expect(e.queued, 4);
      for (var i = 0; i < 5; i++) {
        backend.finishVoice();
        await flush();
      }
      expect(backend.voices, ['run_resume', 'run_gps_back', 'run_chest', 'run_supply', 'run_half']);
      e.dispose();
    });

    test('missing recording falls back to TTS of its line; missing sfx stays silent', () async {
      final b = RecordingAudioBackend(
        assets: {for (final s in Sounds.all) ...s.assets}..removeAll(['audio/voice/run/run_go.m4a', 'audio/sfx/claim_1.m4a', 'audio/sfx/claim_2.m4a']),
      );
      final e = make(b: b);
      e.say(Sounds.runGo);
      e.play(Sounds.claim);
      e.play(Sounds.uiTab);
      await flush();
      expect(b.spoken, ['出发！今天去圈哪块地？']);
      expect(b.voices, isEmpty);
      expect(b.shorts.single, startsWith('ui_tab_'));
      e.dispose();
    });

    test('clip + TTS parts are said back to back; interrupt stops the current line', () async {
      engine.sayParts([const VoicePart.clip(Sounds.coachNext), const VoicePart.tts('深蹲')], kind: 'next');
      await flush();
      expect(backend.voices, ['coach_next']);
      backend.finishVoice();
      await flush();
      expect(backend.spoken, ['深蹲']);
      engine.say(Sounds.coach3, priority: VoicePriority.countdown, interrupt: true);
      await flush();
      expect(backend.log, contains('stop_voice'));
      expect(backend.voices.last, 'coach_3');
      backend.finishVoice();
      await flush();
    });

    test('voice switched off: nothing is queued; switching off stops the current line', () async {
      engine.say(Sounds.runResume);
      await flush();
      engine.setEnabled(SoundChannel.voice, false);
      await flush();
      expect(backend.log, contains('stop_voice'));
      engine.say(Sounds.runPause);
      engine.sayText('第 2 公里', kind: 'km');
      await flush();
      expect(backend.voices, ['run_resume']);
      expect(backend.spoken, isEmpty);
    });
  });

  test('channel switches gate playback; 试听 plays anyway', () async {
    final b = RecordingAudioBackend();
    final e = make(b: b);
    e.setEnabled(SoundChannel.sfx, false);
    e.setEnabled(SoundChannel.character, false);
    e.play(Sounds.uiTab);
    e.play(Sounds.bossTap('bat'));
    e.startLoop(Sounds.runHold);
    await flush();
    expect(b.log, isEmpty);
    e.preview(SoundChannel.sfx);
    e.preview(SoundChannel.character);
    await flush();
    expect(b.played('claim'), isTrue);
    expect(b.played('pet_gecko_tap'), isTrue);
    e.dispose();
  });

  test('settings are persisted and read back', () async {
    final kv = MemoryCache();
    final e = make(kv: kv);
    e.setEnabled(SoundChannel.voice, false);
    e.setVolume(SoundChannel.character, 0.3);
    await flush();
    e.dispose();

    final e2 = make(kv: kv);
    var notified = 0;
    e2.addListener(() => notified++);
    await flush();
    expect(e2.isEnabled(SoundChannel.voice), isFalse);
    expect(e2.isEnabled(SoundChannel.sfx), isTrue);
    expect(e2.volumeOf(SoundChannel.character), closeTo(0.3, 1e-9));
    expect(e2.volumeOf(SoundChannel.sfx), 1);
    expect(notified, 1);
    e2.dispose();
  });

  test('backend failures never throw', () async {
    final e = AudioEngine(backend: _ThrowingBackend(), kv: _ThrowingKv());
    e.play(Sounds.uiTab);
    e.say(Sounds.runGo);
    e.sayText('hi', kind: 'x');
    e.startLoop(Sounds.runHold);
    e.stopLoop();
    e.haptic(HapticKind.heavy);
    e.setVolume(SoundChannel.sfx, 0.2);
    await flush();
    e.dispose();
  });
}

class _VolumeBackend extends RecordingAudioBackend {
  _VolumeBackend(this.vols);
  final Map<String, double> vols;
  @override
  Future<void> playShort(String asset, double volume, SoundChannel channel) async => vols[asset] = volume;
}

class _ThrowingBackend implements AudioBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(StateError('boom'));
}

class _ThrowingKv implements KvCache {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(StateError('disk'));
}
