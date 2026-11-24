import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_api.dart';
import '../../api/community_models.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// D-03 举报: pick a reason, optional detail (≤ 200), `POST /v1/reports`.
/// target_type: `post | comment | user | crew | message`.
Future<bool> showReportSheet(BuildContext context, WidgetRef ref, {required String targetType, required int targetId}) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ReportSheet(targetType: targetType, targetId: targetId),
  );
  return sent == true;
}

class ReportSheet extends ConsumerStatefulWidget {
  const ReportSheet({super.key, required this.targetType, required this.targetId});
  final String targetType;
  final int targetId;
  @override
  ConsumerState<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<ReportSheet> {
  String? _reason;
  final _detail = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final r = _reason;
    if (r == null) return;
    setState(() => _busy = true);
    final id = await runGuarded(
        context, () => ref.read(communityApiProvider).report(widget.targetType, widget.targetId, r, detail: _detail.text));
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) {
      final show = toaster(context);
      Navigator.pop(context, true);
      show('举报已提交，我们会尽快处理', kind: ToastKind.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    const what = {'post': '动态', 'comment': '评论', 'user': '用户', 'crew': '跑团', 'message': '消息'};
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('举报${what[widget.targetType] ?? ''}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        const Text('请选择原因，我们会尽快核实处理', style: TextStyle(color: LL.text2, fontSize: 13)),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in reportReasons.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _reason == e.key,
              onSelected: (_) => setState(() => _reason = e.key),
              selectedColor: LL.lime,
              backgroundColor: LL.card2,
              side: BorderSide.none,
              labelStyle: TextStyle(color: _reason == e.key ? LL.ink : LL.text, fontWeight: FontWeight.w700),
              showCheckmark: false,
            ),
        ]),
        const SizedBox(height: 14),
        TextField(
          controller: _detail,
          maxLength: 200,
          maxLines: 3,
          minLines: 2,
          decoration: const InputDecoration(hintText: '补充说明（选填）'),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _reason == null || _busy ? null : _submit,
            child: Text(_busy ? '提交中…' : '提交举报'),
          ),
        ),
      ]),
    );
  }
}
