import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'ai_providers.dart';
import 'ai_widgets.dart';

const _inkSoft = Color(0xFF2B300E);

/// C-05 AI 战报 on the settlement page: requested once the run is settled,
/// typed in, labelled 「内容由 AI 生成」, 「换一换」 while regenerations last.
class AIReportCard extends ConsumerWidget {
  const AIReportCard({super.key, required this.activityId});
  final int activityId;

  Future<void> _regenerate(BuildContext context, WidgetRef ref) async {
    final err = await ref.read(aiReportProvider(activityId).notifier).regenerate();
    if (err != null && context.mounted) showError(context, err);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(aiReportProvider(activityId));
    final r = st.report;
    final left = r?.regenerateLeft ?? 0;
    return Container(
      key: const Key('ai-report-card'),
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 16),
      decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(26)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const LIcon(LIcons.quan, color: LL.ink, size: 20),
          const SizedBox(width: 6),
          const Expanded(child: Text('AI 战报', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 15))),
          if (r != null)
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: LL.ink, disabledForegroundColor: const Color(0x88121212)),
              onPressed: st.busy || left <= 0 ? null : () => _regenerate(context, ref),
              icon: st.regenerating
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: LL.ink))
                  : const LIcon(LIcons.refresh, size: 18),
              label: Text(left > 0 ? '换一换 · 剩 $left 次' : '已换完'),
            ),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _body(context, ref, st),
        ),
      ]),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, AIReportState st) {
    final r = st.report;
    if (r != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TypingText(
          key: ValueKey(r.text),
          text: r.text,
          style: const TextStyle(color: LL.ink, fontSize: 17, fontWeight: FontWeight.w800, height: 1.5),
        ),
        const SizedBox(height: 8),
        if (r.aiGenerated)
          AILabel(color: _inkSoft, text: r.modelName.isEmpty ? '内容由 AI 生成' : '内容由 AI 生成 · ${r.modelName}'),
      ]);
    }
    if (st.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: LL.ink)),
          SizedBox(width: 10),
          Text('圈圈正在写这次的战报…', style: TextStyle(color: _inkSoft)),
        ]),
      );
    }
    final e = st.error == null ? null : ApiException.from(st.error!);
    return Row(children: [
      Expanded(
        child: Text(
          e?.code == 'ai_unavailable' ? 'AI 战报暂时不可用，稍后可以在这里重试' : '战报生成失败：${e?.message ?? ''}',
          style: const TextStyle(color: _inkSoft),
        ),
      ),
      TextButton(
        style: TextButton.styleFrom(foregroundColor: LL.ink),
        onPressed: () => ref.read(aiReportProvider(activityId).notifier).load(),
        child: const Text('重试'),
      ),
    ]);
  }
}

/// Reveals [text] character by character (AI 「打字」 effect), about 30 ms
/// per character and at most 2.5 s in total.
class TypingText extends StatefulWidget {
  const TypingText({super.key, required this.text, this.style});
  final String text;
  final TextStyle? style;
  @override
  State<TypingText> createState() => _TypingTextState();
}

class _TypingTextState extends State<TypingText> with SingleTickerProviderStateMixin {
  late final List<String> _chars = widget.text.characters.toList();
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_chars.length * 30).clamp(300, 2500)),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final n = (_chars.length * _c.value).ceil().clamp(0, _chars.length);
          return Semantics(
            label: widget.text,
            excludeSemantics: true,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: _chars.take(n).join()),
                // Keep the final height while typing so the card does not jump.
                TextSpan(text: _chars.skip(n).join(), style: const TextStyle(color: Colors.transparent)),
              ]),
              style: widget.style,
            ),
          );
        },
      );
}
