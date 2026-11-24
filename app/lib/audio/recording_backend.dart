import 'dart:async';

import 'audio_backend.dart';
import 'sound_catalog.dart';

/// Records what would be played instead of playing it (tests, screenshots).
///
/// [log] holds one line per call: `short:audio/sfx/claim_1.m4a`,
/// `voice:audio/voice/run/run_go.m4a`, `tts:第 1 公里…`, `loop:…`,
/// `loop_stop`, `haptic:medium`, `duck:true`, `stop_voice`.
class RecordingAudioBackend implements AudioBackend {
  RecordingAudioBackend({Set<String>? assets, this.autoComplete = true})
    : assets = assets ?? {for (final s in Sounds.all) ...s.assets};

  /// The "bundled" assets; remove some to test the TTS fallback.
  final Set<String> assets;

  /// Voice items finish at once; otherwise call [finishVoice].
  final bool autoComplete;

  final log = <String>[];
  final _pending = <Completer<void>>[];

  /// File stems of the short sounds played (`claim_1`, `ui_tab_2` …).
  List<String> get shorts => [
    for (final l in log)
      if (l.startsWith('short:')) _stem(l),
  ];

  /// File stems of the recorded voice lines played.
  List<String> get voices => [
    for (final l in log)
      if (l.startsWith('voice:')) _stem(l),
  ];

  /// Lines read by TTS.
  List<String> get spoken => [
    for (final l in log)
      if (l.startsWith('tts:')) l.substring(4),
  ];

  List<String> get haptics => [
    for (final l in log)
      if (l.startsWith('haptic:')) l.substring(7),
  ];

  /// Whether a short sound or voice line of [id] was played (any variant).
  bool played(String id) =>
      [...shorts, ...voices].any((s) => s == id || RegExp('^${RegExp.escape(id)}_\\d\$').hasMatch(s));

  static String _stem(String line) {
    final f = line.substring(line.lastIndexOf('/') + 1);
    return f.endsWith('.m4a') ? f.substring(0, f.length - 4) : f;
  }

  void clear() => log.clear();

  /// Completes the oldest voice item still playing.
  void finishVoice() {
    if (_pending.isNotEmpty) _pending.removeAt(0).complete();
  }

  Future<void> _wait() {
    if (autoComplete) return Future.value();
    final c = Completer<void>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<Set<String>> bundledAssets() async => assets;
  @override
  Future<void> playShort(String asset, double volume, SoundChannel channel) async => log.add('short:$asset');
  @override
  Future<void> playVoice(String asset, double volume) {
    log.add('voice:$asset');
    return _wait();
  }

  @override
  Future<void> speak(String text, double volume) {
    log.add('tts:$text');
    return _wait();
  }

  @override
  Future<void> stopVoice() async {
    log.add('stop_voice');
    for (final c in _pending) {
      c.complete();
    }
    _pending.clear();
  }

  @override
  Future<void> setDucking(bool duck) async => log.add('duck:$duck');
  @override
  Future<void> startLoop(String asset, double volume) async => log.add('loop:$asset');
  @override
  Future<void> stopLoop() async => log.add('loop_stop');
  @override
  Future<void> haptic(HapticKind kind) async => log.add('haptic:${kind.name}');
  @override
  Future<void> preload(List<String> assets) async {}
  @override
  Future<void> dispose() async {
    for (final c in _pending) {
      c.complete();
    }
    _pending.clear();
  }
}
