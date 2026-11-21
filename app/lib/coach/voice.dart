import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/providers.dart';

/// Spoken cues of AI 跟练 (step start, halfway, 3-2-1, rest, done).
abstract class VoiceCoach {
  Future<void> speak(String text);
  Future<void> stop();
}

/// System text-to-speech in Mandarin. Any failure (no TTS engine, no Chinese
/// voice) is swallowed: the cue is still shown on screen.
class TtsVoiceCoach implements VoiceCoach {
  FlutterTts? _tts;
  Future<FlutterTts?>? _init;

  Future<FlutterTts?> _ready() => _init ??= () async {
        try {
          final t = FlutterTts();
          await t.setLanguage('zh-CN');
          await t.setSpeechRate(kIsWeb ? 1.0 : 0.5);
          await t.setVolume(1);
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
            // Mix with the user's music instead of stopping it.
            await t.setSharedInstance(true);
            await t.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
              IosTextToSpeechAudioCategoryOptions.mixWithOthers,
              IosTextToSpeechAudioCategoryOptions.duckOthers,
            ]);
          }
          return _tts = t;
        } catch (e) {
          debugPrint('coach tts: $e');
          return null;
        }
      }();

  @override
  Future<void> speak(String text) async {
    final t = await _ready();
    if (t == null) return;
    try {
      await t.stop(); // newest cue wins (e.g. 「3」 over a long rest sentence)
      await t.speak(text);
    } catch (e) {
      debugPrint('coach tts: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}

/// Collects cues instead of speaking (tests, screenshots).
class RecordingVoiceCoach implements VoiceCoach {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

final voiceCoachProvider = Provider<VoiceCoach>((ref) => TtsVoiceCoach());

/// 「语音提示」 on / off, remembered on the device. The run page has no
/// voice settings yet, so this is the only switch.
class VoiceMutedNotifier extends Notifier<bool> {
  static const _key = 'coach_voice_muted';

  @override
  bool build() {
    ref.read(kvCacheProvider).read(_key).then((v) {
      if (v != null && ref.mounted) state = v == '1';
    }).ignore();
    return false;
  }

  void toggle() {
    state = !state;
    ref.read(kvCacheProvider).write(_key, state ? '1' : '0').ignore();
  }
}

final voiceMutedProvider = NotifierProvider<VoiceMutedNotifier, bool>(VoiceMutedNotifier.new);
