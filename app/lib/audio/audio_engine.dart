import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/providers.dart' show KvCache;
import 'audio_backend.dart';
import 'sound_catalog.dart';

/// Voice queue priority (docs/音频素材清单.md 一：安全提示 > 圈地成功 > 打怪 >
/// 公里播报 > 其他). [countdown] is above everything and is never held back.
enum VoicePriority { other, km, boss, claim, safety, countdown }

/// One piece of a voice item: a recorded line, or text for the system TTS.
class VoicePart {
  const VoicePart.clip(Sound this.sound) : text = null, variant = null;
  const VoicePart.tts(String this.text) : sound = null, variant = null;
  const VoicePart._clip(Sound this.sound, this.variant) : text = null;
  final Sound? sound;
  final String? text;
  final int? variant;

  @override
  String toString() => sound != null ? 'clip(${sound!.id})' : 'tts($text)';
}

/// Switch + volume of one channel.
@immutable
class ChannelSetting {
  const ChannelSetting({this.enabled = true, this.volume = 1});
  final bool enabled;

  /// 0..1.
  final double volume;

  ChannelSetting copyWith({bool? enabled, double? volume}) =>
      ChannelSetting(enabled: enabled ?? this.enabled, volume: (volume ?? this.volume).clamp(0.0, 1.0));

  Map<String, Object> toJson() => {'on': enabled, 'vol': volume};
  static ChannelSetting fromJson(Object? j) => j is Map
      ? ChannelSetting(
          enabled: j['on'] != false,
          volume: (j['vol'] is num ? (j['vol'] as num).toDouble() : 1.0).clamp(0.0, 1.0),
        )
      : const ChannelSetting();

  @override
  bool operator ==(Object other) => other is ChannelSetting && other.enabled == enabled && other.volume == volume;
  @override
  int get hashCode => Object.hash(enabled, volume);
}

class _VoiceItem {
  _VoiceItem(this.parts, this.priority, this.kind, this.at, this.maxAge);
  final List<VoicePart> parts;
  final VoicePriority priority;
  final String kind;
  final DateTime at;
  final Duration maxAge;
}

/// Plays the app's sounds: three channels (语音播报 / 音效 / 角色声音) with
/// their own switch and volume (persisted), random variants without
/// immediate repeats, haptics, the finish-button loop, and the voice queue.
///
/// Voice queue: one line at a time, highest [VoicePriority] first (FIFO
/// within a priority); the same kind is not repeated within [minInterval]
/// (countdown excepted); items that waited longer than their priority's max
/// age are dropped; at most [maxQueue] items wait. A recorded line whose file
/// is missing is read by the system TTS instead.
///
/// Never throws: every backend failure is swallowed and logged.
class AudioEngine extends ChangeNotifier {
  AudioEngine({
    required this.backend,
    this.kv,
    DateTime Function()? clock,
    math.Random? random,
    this.minInterval = const Duration(seconds: 20),
    this.maxQueue = 4,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? math.Random() {
    _assets = () async {
      try {
        return await backend.bundledAssets();
      } catch (e) {
        debugPrint('audio assets: $e');
        return <String>{};
      }
    }();
    _loadSettings();
  }

  static const _settingsKey = 'audio_settings';

  /// Short sounds play this much below full scale, so the files mastered a
  /// little quiet (Sound.gainsDb) can be boosted up to +2.5 dB.
  static const double shortHeadroom = 0.75;

  final AudioBackend backend;

  /// Where the channel settings are kept (null: not persisted).
  final KvCache? kv;
  final DateTime Function() _clock;
  final math.Random _random;
  final Duration minInterval;
  final int maxQueue;

  late final Future<Set<String>> _assets;
  final _settings = <SoundChannel, ChannelSetting>{for (final c in SoundChannel.values) c: const ChannelSetting()};
  final _lastVariant = <String, int>{};
  final _lastKind = <String, DateTime>{};
  final _queue = <_VoiceItem>[];
  bool _speaking = false;
  bool _ducked = false;
  int _generation = 0;
  bool _loopOn = false;
  bool _disposed = false;

  /// What is being said right now (tests, debugging).
  VoicePart? current;

  // ── settings ──

  ChannelSetting setting(SoundChannel c) => _settings[c]!;
  bool isEnabled(SoundChannel c) => _settings[c]!.enabled;
  double volumeOf(SoundChannel c) => _settings[c]!.volume;

  void setEnabled(SoundChannel c, bool on) => _update(c, _settings[c]!.copyWith(enabled: on));
  void setVolume(SoundChannel c, double v) => _update(c, _settings[c]!.copyWith(volume: v));

  void _update(SoundChannel c, ChannelSetting s) {
    if (_settings[c] == s) return;
    _settings[c] = s;
    if (c == SoundChannel.voice && !s.enabled) stopVoice();
    if (c == SoundChannel.sfx && !s.enabled) stopLoop();
    _saved = true;
    _saveSettings();
    if (!_disposed) notifyListeners();
  }

  /// Settings changed before the saved ones were read win.
  bool _saved = false;

  Future<void> _loadSettings() async {
    try {
      final raw = await kv?.read(_settingsKey);
      if (raw == null || _saved || _disposed) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      for (final c in SoundChannel.values) {
        _settings[c] = ChannelSetting.fromJson(j[c.name]);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('audio settings: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      await kv?.write(_settingsKey, jsonEncode({for (final c in SoundChannel.values) c.name: _settings[c]!.toJson()}));
    } catch (e) {
      debugPrint('audio settings: $e');
    }
  }

  // ── helpers ──

  Future<void> _guard(String what, Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      debugPrint('audio $what: $e');
    }
  }

  /// Random variant (1-based), never the same as the previous one.
  int _pick(Sound s) {
    if (s.variants <= 1) return 1;
    final last = _lastVariant[s.id];
    var v = 1 + _random.nextInt(last == null ? s.variants : s.variants - 1);
    if (last != null && v >= last) v++;
    _lastVariant[s.id] = v;
    return v;
  }

  double _volume(Sound s, int variant) {
    final base = volumeOf(s.channel);
    if (s.channel == SoundChannel.voice) return base;
    final gain = math.pow(10, s.gainDb(variant) / 20).toDouble();
    return (base * shortHeadroom * gain).clamp(0.0, 1.0);
  }

  // ── short sounds ──

  /// Plays a sound effect / character sound (voice lines go through [say]).
  /// [force] plays even when the channel is switched off (试听).
  void play(Sound? s, {bool force = false}) {
    if (s == null || _disposed) return;
    if (s.channel == SoundChannel.voice) {
      say(s);
      return;
    }
    if (!force && !isEnabled(s.channel)) return;
    final v = _pick(s);
    final asset = s.asset(v);
    final vol = _volume(s, v);
    if (vol <= 0) return;
    _guard('play ${s.id}', () async {
      final have = await _assets;
      if (have.isNotEmpty && !have.contains(asset)) return; // missing sfx: just silent
      await backend.playShort(asset, vol, s.channel);
    });
  }

  /// Starts the looping sound (长按结束蓄力) until [stopLoop].
  void startLoop(Sound s) {
    if (_disposed || !isEnabled(s.channel) || _loopOn) return;
    _loopOn = true;
    _guard('loop ${s.id}', () => backend.startLoop(s.asset(1), _volume(s, 1)));
  }

  void stopLoop() {
    if (!_loopOn) return;
    _loopOn = false;
    _guard('stop loop', backend.stopLoop);
  }

  void haptic(HapticKind k) {
    if (_disposed) return;
    _guard('haptic', () => backend.haptic(k));
  }

  /// Warms up the short sounds.
  void preload() => _guard('preload', () async {
    final have = await _assets;
    await backend.preload([
      for (final s in Sounds.all)
        if (s.channel != SoundChannel.voice)
          for (final a in s.assets)
            if (have.isEmpty || have.contains(a)) a,
    ]);
  });

  // ── voice queue ──

  static Duration _maxAge(VoicePriority p) => switch (p) {
    VoicePriority.countdown => const Duration(seconds: 2),
    VoicePriority.safety => const Duration(seconds: 30),
    VoicePriority.claim => const Duration(seconds: 15),
    VoicePriority.boss => const Duration(seconds: 15),
    VoicePriority.km => const Duration(seconds: 20),
    VoicePriority.other => const Duration(seconds: 8),
  };

  /// Queues a recorded line (random variant).
  ///
  /// [kind] groups lines for the minimum interval (default: the sound id);
  /// [interval] overrides [minInterval] (countdown: always zero);
  /// [interrupt] stops whatever is being said and clears the queue (newest
  /// cue wins: the 3-2-1, AI 跟练).
  void say(
    Sound s, {
    VoicePriority priority = VoicePriority.other,
    String? kind,
    Duration? interval,
    bool interrupt = false,
  }) => sayParts(
    [VoicePart._clip(s, _pick(s))],
    priority: priority,
    kind: kind ?? s.id,
    interval: interval,
    interrupt: interrupt,
  );

  /// Queues a dynamic line for the system TTS (每公里、总结…).
  void sayText(
    String text, {
    VoicePriority priority = VoicePriority.other,
    required String kind,
    Duration? interval,
    bool interrupt = false,
  }) => sayParts([VoicePart.tts(text)], priority: priority, kind: kind, interval: interval, interrupt: interrupt);

  /// Queues several parts said back to back as one item (「下一个动作：」 + TTS).
  /// [maxAge] overrides how long the item may wait (default by priority);
  /// [force] queues it even when the voice channel is off (试听).
  void sayParts(
    List<VoicePart> parts, {
    VoicePriority priority = VoicePriority.other,
    required String kind,
    Duration? interval,
    Duration? maxAge,
    bool interrupt = false,
    bool force = false,
  }) {
    if (_disposed || parts.isEmpty) return;
    if (!force && !isEnabled(SoundChannel.voice)) return;
    final now = _clock();
    final gap = priority == VoicePriority.countdown ? Duration.zero : (interval ?? minInterval);
    final last = _lastKind[kind];
    if (gap > Duration.zero && last != null && now.difference(last) < gap) {
      debugPrint('audio voice: skip $kind (said ${now.difference(last).inSeconds}s ago)');
      return;
    }
    _lastKind[kind] = now;
    if (interrupt) {
      _queue.clear();
      if (_speaking) {
        _generation++;
        _guard('stop voice', backend.stopVoice);
      }
    }
    final item = _VoiceItem(parts, priority, kind, now, maxAge ?? _maxAge(priority));
    // Highest priority first, FIFO within a priority.
    var i = _queue.indexWhere((q) => q.priority.index < priority.index);
    if (i < 0) i = _queue.length;
    _queue.insert(i, item);
    while (_queue.length > maxQueue) {
      final dropped = _queue.removeLast();
      debugPrint('audio voice: queue full, drop ${dropped.kind}');
    }
    _pump();
  }

  /// Stops the current line and forgets the queue.
  void stopVoice() {
    _queue.clear();
    if (_speaking) {
      _generation++;
      _guard('stop voice', backend.stopVoice);
    }
  }

  /// Number of items waiting (tests).
  @visibleForTesting
  int get queued => _queue.length;

  Future<void> _pump() async {
    if (_speaking) return;
    _speaking = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final item = _queue.removeAt(0);
        if (_clock().difference(item.at) > item.maxAge) {
          debugPrint('audio voice: stale ${item.kind}');
          continue;
        }
        if (!_ducked) {
          _ducked = true;
          await _guard('duck', () => backend.setDucking(true));
        }
        final gen = _generation;
        for (final p in item.parts) {
          if (gen != _generation || _disposed) break;
          current = p;
          await _say(p);
        }
        current = null;
      }
    } finally {
      _speaking = false;
      current = null;
      if (_ducked && !_disposed) {
        _ducked = false;
        await _guard('unduck', () => backend.setDucking(false));
      }
    }
    // Something may have been queued while un-ducking.
    if (_queue.isNotEmpty && !_disposed) unawaited(_pump());
  }

  Future<void> _say(VoicePart p) async {
    final vol = volumeOf(SoundChannel.voice);
    final s = p.sound;
    if (s == null) {
      await _guard('tts', () => backend.speak(p.text!, vol));
      return;
    }
    final v = p.variant ?? 1;
    final asset = s.asset(v);
    final have = await _assets;
    if (have.isEmpty || have.contains(asset)) {
      await _guard('voice ${s.id}', () => backend.playVoice(asset, vol));
    } else {
      // Missing recording: read the line with the system TTS.
      await _guard('tts ${s.id}', () => backend.speak(s.textOf(v), vol));
    }
  }

  // ── 试听 ──

  /// Plays a sample of [c] (even when it is switched off).
  void preview(SoundChannel c) {
    switch (c) {
      case SoundChannel.voice:
        sayParts(
          [VoicePart._clip(Sounds.runGo, 1)],
          kind: 'preview',
          interval: Duration.zero,
          interrupt: true,
          force: true,
        );
      case SoundChannel.sfx:
        play(Sounds.claim, force: true);
      case SoundChannel.character:
        play(Sounds.petTap('gecko'), force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    _guard('dispose', backend.dispose);
    super.dispose();
  }
}
