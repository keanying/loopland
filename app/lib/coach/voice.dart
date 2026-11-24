import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio.dart';
import '../core/providers.dart';
import 'coach_session.dart';

/// Spoken cues of AI 跟练 (step start, halfway, 3-2-1, rest, done).
abstract class VoiceCoach {
  /// Says a session cue (recorded clips where there is one, TTS for the rest).
  Future<void> cue(CoachCue c);

  /// Reads [text] with the system TTS.
  Future<void> speak(String text);
  Future<void> stop();
}

/// Cues through the app's [AudioEngine] (voice channel, 设置 → 声音): the
/// fixed cues use the recorded coach clips (voice/coach), moves and numbers
/// the system TTS. The newest cue wins (「3」 over a long rest sentence).
class EngineVoiceCoach implements VoiceCoach {
  EngineVoiceCoach(this.audio);
  final AudioEngine audio;

  void _say(List<VoicePart> parts, {VoicePriority priority = VoicePriority.claim}) =>
      audio.sayParts(parts, priority: priority, kind: 'coach', interval: Duration.zero, interrupt: true);

  @override
  Future<void> cue(CoachCue c) async {
    final tail = c.detail;
    switch (c.kind) {
      case CueKind.countdown:
        final n = int.tryParse(c.text);
        if (n == null || n < 1 || n > 3) return _say([VoicePart.tts(c.text)], priority: VoicePriority.countdown);
        _say([VoicePart.clip(Sounds.coachCount(n))], priority: VoicePriority.countdown);
      case CueKind.prepare:
        _say([const VoicePart.clip(Sounds.coachReady), VoicePart.tts(c.text)]);
      case CueKind.start:
        _say([if (tail != null) const VoicePart.clip(Sounds.coachNext), VoicePart.tts(tail ?? c.text)]);
      case CueKind.half:
        _say([const VoicePart.clip(Sounds.coachHalfway)]);
      case CueKind.last10:
        _say([const VoicePart.clip(Sounds.coachLast10)]);
      case CueKind.rest:
        _say([const VoicePart.clip(Sounds.coachRest), VoicePart.tts(tail ?? c.text)]);
      case CueKind.done:
        _say(tail == null ? [VoicePart.tts(c.text)] : [const VoicePart.clip(Sounds.coachDone), VoicePart.tts(tail)]);
      case CueKind.almost:
        _say([VoicePart.tts(c.text)]);
    }
  }

  @override
  Future<void> speak(String text) async => _say([VoicePart.tts(text)]);

  @override
  Future<void> stop() async => audio.stopVoice();
}

/// Collects cues instead of speaking (tests, screenshots).
class RecordingVoiceCoach implements VoiceCoach {
  final spoken = <String>[];
  final cues = <CoachCue>[];
  @override
  Future<void> cue(CoachCue c) async {
    cues.add(c);
    spoken.add(c.text);
  }

  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

final voiceCoachProvider = Provider<VoiceCoach>((ref) => EngineVoiceCoach(ref.read(audioProvider)));

/// 「语音提示」 on / off of AI 跟练, remembered on the device (the app-wide
/// switch is 设置 → 声音 → 语音播报).
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
