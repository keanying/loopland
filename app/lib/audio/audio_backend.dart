import 'sound_catalog.dart';

/// Haptic patterns paired with key moments.
enum HapticKind {
  /// 点按、开始按钮.
  light,

  /// 圈地成功、开宝箱.
  medium,

  /// 长按结束、击败怪兽.
  heavy,

  /// 开关.
  selection,
}

/// What actually makes noise. The engine ([AudioEngine]) decides what to
/// play and when; a backend only plays. Every method must swallow its own
/// errors — the engine also guards each call.
///
/// Implementations: [AudioplayersBackend] (the app), [SilentAudioBackend]
/// (widget tests, unsupported platforms), [RecordingAudioBackend] (tests).
abstract class AudioBackend {
  /// Asset keys (relative to `assets/`, e.g. `audio/sfx/claim_1.m4a`) that are
  /// bundled. Missing voice lines fall back to TTS.
  Future<Set<String>> bundledAssets();

  /// Fire-and-forget short sound (sfx / character), [volume] 0..1.
  Future<void> playShort(String asset, double volume, SoundChannel channel);

  /// One voice clip; completes when it has finished playing (or failed).
  Future<void> playVoice(String asset, double volume);

  /// Speaks [text] with the system TTS; completes when done (or failed).
  Future<void> speak(String text, double volume);

  /// Stops the current voice clip / TTS.
  Future<void> stopVoice();

  /// Called before the first voice item of a burst and after the queue ran
  /// empty: lower (duck) the user's music while圈圈 speaks.
  Future<void> setDucking(bool duck);

  /// Starts / stops the single looping sound (长按结束蓄力).
  Future<void> startLoop(String asset, double volume);
  Future<void> stopLoop();

  Future<void> haptic(HapticKind kind);

  /// Warms up the short sounds (decode / copy to cache) to cut first-play
  /// latency.
  Future<void> preload(List<String> assets);

  Future<void> dispose();
}

/// Plays nothing; every voice item completes at once.
class SilentAudioBackend implements AudioBackend {
  @override
  Future<Set<String>> bundledAssets() async => {for (final s in Sounds.all) ...s.assets};
  @override
  Future<void> playShort(String asset, double volume, SoundChannel channel) async {}
  @override
  Future<void> playVoice(String asset, double volume) async {}
  @override
  Future<void> speak(String text, double volume) async {}
  @override
  Future<void> stopVoice() async {}
  @override
  Future<void> setDucking(bool duck) async {}
  @override
  Future<void> startLoop(String asset, double volume) async {}
  @override
  Future<void> stopLoop() async {}
  @override
  Future<void> haptic(HapticKind kind) async {}
  @override
  Future<void> preload(List<String> assets) async {}
  @override
  Future<void> dispose() async {}
}
