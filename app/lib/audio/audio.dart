// 声音：语音播报、音效、角色声音和震动。说明见 docs/音频素材清单.md「接入说明」。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import 'audio_backend.dart';
import 'audio_engine.dart';
import 'audioplayers_backend.dart';
import 'sound_catalog.dart';
import 'test_env_web.dart' if (dart.library.io) 'test_env_io.dart';

export 'audio_backend.dart';
export 'audio_engine.dart';
export 'sound_catalog.dart';

/// The app's [AudioEngine]. Tests override it with
/// `AudioEngine(backend: RecordingAudioBackend())`; without an override,
/// `flutter test` gets a silent backend (no platform channels).
final audioProvider = Provider<AudioEngine>((ref) {
  final AudioBackend backend = isFlutterTest ? SilentAudioBackend() : AudioplayersBackend();
  final e = AudioEngine(backend: backend, kv: ref.read(kvCacheProvider));
  if (!isFlutterTest) e.preload();
  ref.onDispose(e.dispose);
  return e;
});

/// The engine from a widget without a `ref` (toasts, plain widgets), or null
/// outside a ProviderScope.
AudioEngine? audioOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(context, listen: false).read(audioProvider);
  } catch (_) {
    return null;
  }
}

/// Plays [s] from a widget without a `ref`.
void playSound(BuildContext context, Sound? s, {HapticKind? haptic}) {
  final a = audioOf(context);
  if (a == null) return;
  a.play(s);
  if (haptic != null) a.haptic(haptic);
}
