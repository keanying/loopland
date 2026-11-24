import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'audio_backend.dart';
import 'sound_catalog.dart';

/// The app's backend: `audioplayers` for the clips (Android / iOS / web) and
/// the system TTS (`flutter_tts`) for dynamic lines.
///
/// Audio session:
/// * short sounds (sfx / character) mix with the user's music and never take
///   audio focus; on iOS they use the `ambient` category, so the silent
///   switch mutes them; on Android they play as sonification (muted with the
///   system sounds in silent / vibrate mode on most phones);
/// * voice (clips + TTS) mixes with the music and ducks it while圈圈 speaks:
///   Android `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`; iOS switches the shared
///   session to `playback` + `mixWithOthers` + `duckOthers` for the burst
///   and back to `ambient` afterwards (iOS has one session per app, and
///   ducking needs `playback`, which ignores the silent switch).
class AudioplayersBackend implements AudioBackend {
  AudioplayersBackend({this.shortPlayers = 4});

  /// Simultaneous short sounds (round-robin).
  final int shortPlayers;

  final _cache = AudioCache(prefix: 'assets/');
  final List<AudioPlayer> _short = [];
  int _next = 0;
  AudioPlayer? _voice, _loop;
  FlutterTts? _tts;
  Future<FlutterTts?>? _ttsInit;
  Completer<void>? _voiceDone;
  bool _disposed = false;

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _ios => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static final _shortContext = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient, options: const {}),
  );

  static final _voiceContext = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.assistanceNavigationGuidance,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers, AVAudioSessionOptions.duckOthers},
    ),
  );

  static Future<void> _guard(String what, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('audio $what: $e');
    }
  }

  Future<AudioPlayer> _newPlayer(AudioContext ctx, {bool lowLatency = false}) async {
    final p = AudioPlayer()..audioCache = _cache;
    // iOS has one session per app: it is set globally (see [setDucking]).
    if (!_ios && !kIsWeb) await p.setAudioContext(ctx);
    await p.setReleaseMode(ReleaseMode.stop);
    if (lowLatency && _android) await p.setPlayerMode(PlayerMode.lowLatency);
    return p;
  }

  Future<void>? _ready;
  Future<void> _init() => _ready ??= () async {
    if (_ios) await _guard('ios session', () => AudioPlayer.global.setAudioContext(_shortContext));
  }();

  @override
  Future<Set<String>> bundledAssets() async {
    try {
      final m = await AssetManifest.loadFromAssetBundle(rootBundle);
      return {
        for (final a in m.listAssets())
          if (a.startsWith('assets/audio/')) a.substring('assets/'.length),
      };
    } catch (e) {
      debugPrint('audio manifest: $e');
      // Unknown: assume everything is there (players fail quietly if not).
      return {for (final s in Sounds.all) ...s.assets};
    }
  }

  @override
  Future<void> playShort(String asset, double volume, SoundChannel channel) => _guard('play $asset', () async {
    if (_disposed) return;
    await _init();
    while (_short.length < shortPlayers) {
      _short.add(await _newPlayer(_shortContext, lowLatency: true));
    }
    final p = _short[_next];
    _next = (_next + 1) % _short.length;
    await p.stop();
    await p.play(AssetSource(asset), volume: volume);
  });

  @override
  Future<void> playVoice(String asset, double volume) async {
    if (_disposed) return;
    final done = Completer<void>();
    _voiceDone = done;
    StreamSubscription<void>? sub;
    await _guard('voice $asset', () async {
      await _init();
      final p = _voice ??= await _newPlayer(_voiceContext);
      sub = p.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      await p.play(AssetSource(asset), volume: volume);
    });
    // Lines are ≤ 4 s; never let a lost completion event block the queue.
    await done.future.timeout(const Duration(seconds: 6), onTimeout: () {});
    await sub?.cancel();
    if (!done.isCompleted) done.complete();
  }

  Future<FlutterTts?> _ttsReady() => _ttsInit ??= () async {
    try {
      final t = FlutterTts();
      await t.setLanguage('zh-CN');
      await t.setSpeechRate(kIsWeb ? 1.0 : 0.5);
      await t.awaitSpeakCompletion(true);
      if (_ios) {
        await t.setSharedInstance(true);
        await t.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.duckOthers,
        ]);
      }
      if (_android) await t.setAudioAttributesForNavigation();
      return _tts = t;
    } catch (e) {
      debugPrint('audio tts: $e');
      return null;
    }
  }();

  @override
  Future<void> speak(String text, double volume) async {
    if (_disposed || text.trim().isEmpty) return;
    final t = await _ttsReady();
    if (t == null) return;
    // awaitSpeakCompletion: completes when the sentence is done. Cap it so a
    // TTS engine that never reports back cannot block the queue.
    final cap = Duration(seconds: 4 + text.length ~/ 3);
    await _guard('tts', () async {
      await t.setVolume(volume);
      await t.speak(text, focus: true).timeout(cap, onTimeout: () => null);
    });
  }

  @override
  Future<void> stopVoice() async {
    final d = _voiceDone;
    if (d != null && !d.isCompleted) d.complete();
    await _guard('stop voice', () async => _voice?.stop());
    await _guard('stop tts', () async => _tts?.stop());
  }

  @override
  Future<void> setDucking(bool duck) => _guard('ducking', () async {
    if (!_ios) return; // Android: each voice clip / TTS line requests MAY_DUCK focus itself.
    await AudioPlayer.global.setAudioContext(duck ? _voiceContext : _shortContext);
  });

  @override
  Future<void> startLoop(String asset, double volume) => _guard('loop $asset', () async {
    if (_disposed) return;
    await _init();
    final p = _loop ??= await _newPlayer(_shortContext);
    await p.setReleaseMode(ReleaseMode.loop);
    await p.play(AssetSource(asset), volume: volume);
  });

  @override
  Future<void> stopLoop() => _guard('stop loop', () async => _loop?.stop());

  @override
  Future<void> haptic(HapticKind kind) => _guard('haptic', () async {
    if (kIsWeb) return;
    switch (kind) {
      case HapticKind.light:
        await HapticFeedback.lightImpact();
      case HapticKind.medium:
        await HapticFeedback.mediumImpact();
      case HapticKind.heavy:
        await HapticFeedback.heavyImpact();
      case HapticKind.selection:
        await HapticFeedback.selectionClick();
    }
  });

  @override
  Future<void> preload(List<String> assets) => _guard('preload', () async {
    // Web fetches on demand (the browser caches); native copies the
    // assets to files once.
    if (kIsWeb) return;
    await _cache.loadAll(assets);
  });

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final p in [..._short, ?_voice, ?_loop]) {
      await _guard('dispose', p.dispose);
    }
    _short.clear();
    await _guard('dispose tts', () async => _tts?.stop());
  }
}
