import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../audio/audio.dart';
import '../../core/theme.dart';
import '../../widgets/l_icons.dart';

/// 设置 →「声音」：语音播报 / 音效 / 角色声音，各自的开关、音量和试听。
/// Saved on this device (not synced to the account).
class SoundSettings extends ConsumerWidget {
  const SoundSettings({super.key});

  static const _rows = [
    (SoundChannel.voice, LIcons.headphones, '跑步、AI 跟练和结算时圈圈的声音'),
    (SoundChannel.sfx, LIcons.volume, '点按、切换、圈地、开宝箱、升级'),
    (SoundChannel.character, LIcons.buddy, '怪兽、伙伴和角色卡的叫声'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioProvider);
    return ListenableBuilder(
      listenable: audio,
      builder: (context, _) => Column(children: [
        for (final (i, (c, icon, hint)) in _rows.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16, color: LL.border),
          _ChannelRow(audio: audio, channel: c, icon: icon, hint: hint),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            '语音播报会混在你的音乐里播放，说话时音乐自动调低。手机静音时音效和角色声音不出声，只保留震动。',
            style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5),
          ),
        ),
      ]),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.audio, required this.channel, required this.icon, required this.hint});
  final AudioEngine audio;
  final SoundChannel channel;
  final LGlyph icon;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final on = audio.isEnabled(channel);
    final vol = audio.volumeOf(channel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
      child: Column(children: [
        Row(children: [
          LIcon(icon, color: on ? LL.lime : LL.text3, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(channel.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              Text(hint, style: const TextStyle(color: LL.text3, fontSize: 12)),
            ]),
          ),
          Semantics(
            button: true,
            label: '试听${channel.label}',
            excludeSemantics: true,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: LL.lavender, padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: () => audio.preview(channel),
              icon: const LIcon(LIcons.playCircle, size: 18),
              label: const Text('试听'),
            ),
          ),
          Switch(
            value: on,
            onChanged: (v) {
              audio.setEnabled(channel, v);
              // The toggle sound only when 音效 itself is (still) on.
              audio.play(v ? Sounds.uiToggleOn : Sounds.uiToggleOff);
              audio.haptic(HapticKind.selection);
            },
          ),
        ]),
        Row(children: [
          const SizedBox(width: 26),
          LIcon(LIcons.volumeOff, size: 16, color: on ? LL.text2 : LL.text3),
          Expanded(
            child: Semantics(
              label: '${channel.label}音量',
              child: Slider(
                value: vol,
                onChanged: on ? (v) => audio.setVolume(channel, v) : null,
                onChangeEnd: on ? (_) => audio.preview(channel) : null,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text('${(vol * 100).round()}%',
                textAlign: TextAlign.end, style: TextStyle(color: on ? LL.text2 : LL.text3, fontSize: 12)),
          ),
          const SizedBox(width: 8),
        ]),
      ]),
    );
  }
}
