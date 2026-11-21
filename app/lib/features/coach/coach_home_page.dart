import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../coach/coach_api.dart';
import '../../coach/workout.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'coach_session_page.dart';

/// `/coach?sport=` — AI 跟练 course list: tabs by sport (跳绳 / HIIT / 普拉提 /
/// 力量), workout cards, and 「手动记录」 for the old free-form home training.
class CoachHomePage extends ConsumerStatefulWidget {
  const CoachHomePage({super.key, this.sport});
  final String? sport;
  @override
  ConsumerState<CoachHomePage> createState() => _CoachHomePageState();
}

class _CoachHomePageState extends ConsumerState<CoachHomePage> {
  static const _order = ['rope', 'hiit', 'yoga', 'strength'];
  String? _sport;

  @override
  void initState() {
    super.initState();
    _sport = widget.sport;
  }

  @override
  Widget build(BuildContext context) {
    final cat = ref.watch(workoutCatalogProvider);
    final sports = <String>{
      for (final s in _order)
        if (cat.value?.items.any((w) => w.sport == s) ?? false) s,
      for (final w in cat.value?.items ?? const <Workout>[])
        if (!_order.contains(w.sport)) w.sport,
    }.toList();
    final sport = sports.contains(_sport) ? _sport! : (sports.isEmpty ? (_sport ?? 'rope') : sports.first);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: 'AI 跟练',
            subtitle: '跟着动作练，摄像头自动计数',
            trailing: TextButton.icon(
              key: const Key('coach-manual-entry'),
              onPressed: () => context.push('/train/${_manualSport(sport)}'),
              icon: const Icon(Icons.edit_note_rounded, size: 20),
              label: const Text('手动记录'),
            ),
          ),
          if (sports.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: ChipTabs(
                labels: [for (final s in sports) sportTab(s)],
                index: sports.indexOf(sport),
                onChanged: (i) => setState(() => _sport = sports[i]),
              ),
            ),
          Expanded(
            child: AsyncBody<WorkoutCatalog>(
              value: cat,
              onRetry: () => ref.invalidate(workoutCatalogProvider),
              data: (c) {
                final items = c.items.where((w) => w.sport == sport).toList();
                final cfg = ref.watch(configProvider).value;
                final energy = cfg?.energyFor(sport)?.text;
                return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                  if (c.builtin)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 10),
                      child: Row(children: [
                        Icon(Icons.info_outline_rounded, size: 16, color: LL.text3),
                        SizedBox(width: 6),
                        Expanded(child: Text('课程库暂时无法更新，先用内置课程', style: TextStyle(color: LL.text3, fontSize: 12))),
                      ]),
                    ),
                  for (final w in items) ...[
                    _WorkoutCard(workout: w, onTap: () => context.push('/coach/${w.key}', extra: w)),
                    const SizedBox(height: 12),
                  ],
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('这个分类还没有课程', style: TextStyle(color: LL.text2))),
                    ),
                  if (energy != null)
                    Row(children: [
                      const Icon(Icons.bolt_rounded, color: LL.yellow, size: 18),
                      const SizedBox(width: 4),
                      Expanded(child: Text('$energy · 居家训练只换能量，不圈地', style: const TextStyle(color: LL.text2, fontSize: 13))),
                    ]),
                  const SizedBox(height: 12),
                  const _PrivacyCard(),
                ]);
              },
            ),
          ),
        ]),
      ),
    );
  }

  /// The manual page knows the four home sports.
  static String _manualSport(String s) => const {'rope', 'hiit', 'yoga', 'strength'}.contains(s) ? s : 'strength';
}

class _WorkoutCard extends StatelessWidget {
  const _WorkoutCard({required this.workout, required this.onTap});
  final Workout workout;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final w = workout;
    return Material(
      color: LL.card,
      borderRadius: BorderRadius.circular(LL.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(LL.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(w.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
              _Tag(text: w.levelName, color: LL.lavender),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 12, runSpacing: 4, children: [
              if (w.estMinutes > 0) _Meta(icon: Icons.schedule_rounded, text: '约 ${w.estMinutes} 分钟'),
              _Meta(icon: Icons.layers_rounded, text: '${w.steps.length} 个动作 · ${w.totalSets} 组'),
              if (w.usesCamera) const _Meta(icon: Icons.videocam_rounded, text: '摄像头自动计数', color: LL.lime),
            ]),
            const SizedBox(height: 12),
            for (final s in w.steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Container(width: 6, height: 6, decoration: const BoxDecoration(color: LL.text3, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text('${s.targetText} × ${s.sets} 组', style: const TextStyle(color: LL.text2, fontSize: 13)),
                ]),
              ),
            const SizedBox(height: 10),
            Row(children: [
              const Spacer(),
              FilledButton.icon(onPressed: onTap, icon: const Icon(Icons.play_arrow_rounded), label: const Text('开始跟练')),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: const TextStyle(color: LL.ink, fontSize: 12, fontWeight: FontWeight.w800)),
      );
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color = LL.text2});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontSize: 12)),
      ]);
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();
  @override
  Widget build(BuildContext context) => const LLCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.privacy_tip_outlined, color: LL.lavender, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '动作识别在手机本地完成，摄像头画面不上传、不保存，只记录次数。'
              '不开摄像头也能练：跟着计时，手动点 +1 计数。',
              style: TextStyle(color: LL.text2, fontSize: 12, height: 1.5),
            ),
          ),
        ]),
      );
}
