import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../run/run_store.dart';
import '../../run/uploader.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/nav_shell.dart';
import '../ai/ai_widgets.dart';
import '../run/result_page.dart';
import '../social/my_social_card.dart';
import '../social/social_providers.dart';
import '../social/social_widgets.dart';

/// 我的。
class MePage extends ConsumerWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(userProvider);
    if (u == null) return const SizedBox.shrink();
    final codex = ref.watch(codexProvider).value;
    final pending = ref.watch(pendingUploadsProvider).value ?? const <PendingUpload>[];
    final w = u.stats.week;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(authProvider.notifier).refreshUser();
            ref.invalidate(pendingUploadsProvider);
            ref.invalidate(codexProvider);
            ref.invalidate(myProfileProvider);
          },
          child: ListView(padding: EdgeInsets.fromLTRB(16, 12, 16, NavShell.bottomInset(context)), children: [
            Row(children: [
              GestureDetector(
                onTap: () => context.push('/users/${u.id}'),
                child: UserAvatar(
                    user: UserBrief(id: u.id, nickname: u.nickname, avatarUrl: u.avatarUrl, avatarFrame: u.equipped.avatarFrame),
                    size: 76),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(u.nickname, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                  Row(children: [
                    const Icon(Icons.bolt_rounded, color: LL.yellow, size: 16),
                    Text(' LV.${u.level} · ${u.energy} 能量', style: const TextStyle(color: LL.text2)),
                    if (u.membership?.active == true) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.workspace_premium_rounded, color: LL.lime, size: 16),
                    ],
                  ]),
                  if (u.crew != null) Text('「${u.crew!.name}」', style: const TextStyle(color: LL.lavender)),
                ]),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                onPressed: () => context.push('/me/profile'),
                child: const Text('编辑'),
              ),
            ]),
            const SizedBox(height: 14),
            const MySocialCard(),
            if (u.isDeleting) ...[
              const SizedBox(height: 12),
              LLCard(
                color: const Color(0xFF3A1D22),
                onTap: () => context.push('/settings'),
                child: Text('账号注销冷静期中，将于 ${Fmt.dateTime(u.deleteAfter)} 删除。点此撤回。'),
              ),
            ],
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 12),
              _PendingCard(pending: pending),
            ],
            const SizedBox(height: 16),
            LLCard(
              onTap: () => context.go('/codex'),
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                for (final k in _highlights(codex)) Padding(padding: const EdgeInsets.only(right: 6), child: CardArt(artKey: k, width: 52)),
                if (_highlights(codex).isEmpty) const CardArt(artKey: 'gecko', width: 52, locked: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('我的图鉴', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                    Text(codex == null ? '加载中…' : '已收集 ${codex.obtainedCount} / ${codex.totalCount}',
                        style: const TextStyle(color: LL.text2)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: LL.text3),
              ]),
            ),
            const SizedBox(height: 12),
            LLCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('本周运动', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: StatBox(value: '${w.count}', label: '次数')),
                  Expanded(child: StatBox(value: Fmt.km(w.distanceM, digits: 1), unit: 'km', label: '里程')),
                  Expanded(child: StatBox(value: '${(w.durationS / 60).round()}', unit: '分', label: '时长')),
                  Expanded(child: StatBox(value: '${w.energy}', label: '能量')),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(26)),
                  child: StatBox(value: Fmt.area(u.stats.territoryAreaM2), label: '我的领地 · ${u.stats.territoryCount} 块', dark: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(26)),
                  child: StatBox(
                      value: Fmt.km(u.stats.totalDistanceM, digits: 1), unit: 'km', label: '累计 · ${u.stats.activityCount} 次', dark: true),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (!u.isMinor)
              _MenuTile(
                icon: Icons.workspace_premium_outlined,
                color: LL.lime,
                title: u.membership?.active == true ? '会员 · ${u.membership!.planName ?? ''}' : '开通会员',
                sub: u.membership?.active == true ? '到期 ${Fmt.date(u.membership!.expiresAt)}' : '手绘 / 3D 地图、高级数据等体验权益',
                onTap: () => context.push('/membership'),
              ),
            if (ref.watch(aiEnabledProvider))
              _MenuTile(
                icon: Icons.auto_awesome_rounded,
                leading: const AIMark(size: 20),
                color: LL.lavender,
                title: '圈圈',
                sub: '去哪抢地、怪兽怎么打、今天跑多少合适',
                onTap: () => context.push('/ai'),
              ),
            _MenuTile(icon: Icons.history_rounded, color: LL.sky, title: '运动记录', onTap: () => context.push('/activities')),
            _MenuTile(
              icon: Icons.receipt_long_outlined,
              color: LL.lime,
              title: '我的订场',
              sub: '合作场馆订单、取消与退款',
              onTap: () => context.push('/me/bookings'),
            ),
            _MenuTile(
              icon: Icons.confirmation_number_outlined,
              color: LL.pink,
              title: '卡券包',
              sub: '补给站、商户宝箱、据点得到的联名券',
              onTap: () => context.push('/me/coupons'),
            ),
            _MenuTile(icon: Icons.notifications_none_rounded, color: LL.pink, title: '消息', onTap: () => context.push('/inbox')),
            _MenuTile(
              icon: Icons.verified_user_outlined,
              color: LL.yellow,
              title: '实名认证',
              sub: u.realnameVerified ? '已认证' : '未认证',
              onTap: () => context.push('/realname'),
            ),
            _MenuTile(icon: Icons.block_rounded, color: LL.orange, title: '黑名单', onTap: () => context.push('/me/blocks')),
            _MenuTile(icon: Icons.settings_outlined, color: LL.text2, title: '设置与隐私', onTap: () => context.push('/settings')),
            const SizedBox(height: 12),
            // 本地生活（设计稿 08）：订场 · 联名活动 · 能量商城
            Row(children: const [
              Expanded(child: _LocalTile('订场', '合作场馆', Icons.event_available_rounded, LL.lime, '/local?tab=booking')),
              SizedBox(width: 8),
              Expanded(child: _LocalTile('联名福利', '品牌活动', Icons.local_offer_outlined, LL.pink, '/local?tab=campaigns')),
              SizedBox(width: 8),
              Expanded(child: _LocalTile('能量商城', '能量换装扮', Icons.storefront_outlined, LL.sky, '/local?tab=shop')),
            ]),
          ]),
        ),
      ),
    );
  }

  List<String> _highlights(Codex? c) {
    if (c == null) return const [];
    return [
      ...c.roles.where((r) => r.obtained).map((r) => r.key),
      ...c.buildings.where((b) => b.unlocked).map((b) => b.key),
      ...c.companions.where((p) => p.hatched).map((p) => p.key),
    ].take(3).toList();
  }
}

class _PendingCard extends ConsumerStatefulWidget {
  const _PendingCard({required this.pending});
  final List<PendingUpload> pending;
  @override
  ConsumerState<_PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends ConsumerState<_PendingCard> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    final results = await ref.read(uploaderProvider).flush();
    ref.invalidate(pendingUploadsProvider);
    if (!mounted) return;
    setState(() => _busy = false);
    if (results.isNotEmpty) {
      ref.read(authProvider.notifier).refreshUser().ignore();
      context.push('/result', extra: ResultArgs(result: results.last));
    } else {
      toast(context, '还是没有上传成功，请检查网络后再试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    return LLCard(
      color: const Color(0xFF26223A),
      child: Row(children: [
        const Icon(Icons.cloud_upload_outlined, color: LL.lavender),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.length} 条运动等待上传', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(p.first.lastError ?? '网络恢复后会自动上传', style: const TextStyle(color: LL.text2, fontSize: 12)),
          ]),
        ),
        TextButton(onPressed: _busy ? null : _retry, child: Text(_busy ? '上传中…' : '重试')),
      ]),
    );
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.icon, this.leading, required this.color, required this.title, this.sub, required this.onTap});
  final IconData icon;
  final Widget? leading; // 替代 icon（如「圈圈」的带 AI 角标图标）
  final Color color;
  final String title;
  final String? sub;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LLCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: leading ?? Icon(icon, color: LL.ink, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              if (sub != null) Text(sub!, style: const TextStyle(color: LL.text2, fontSize: 12)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: LL.text3),
        ]),
      ),
    );
  }
}

class _LocalTile extends StatelessWidget {
  const _LocalTile(this.title, this.sub, this.icon, this.color, this.path);
  final String title, sub, path;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => LLCard(
        key: Key('local_${title.hashCode}'),
        padding: const EdgeInsets.all(12),
        onTap: () => context.push(path),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color),
          const SizedBox(height: 6),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(sub, style: const TextStyle(color: LL.text3, fontSize: 12)),
        ]),
      );
}
