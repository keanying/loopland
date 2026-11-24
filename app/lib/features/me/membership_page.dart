import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../pay/payment_service.dart';
import '../../widgets/common.dart';
import '../../widgets/sound_refresh.dart';

final plansProvider = FutureProvider.autoDispose<PlansResponse>((ref) => ref.watch(apiProvider).plans());
final membershipProvider = FutureProvider.autoDispose<Membership>((ref) => ref.watch(apiProvider).membership());

const entitlementNames = {
  'map_styles': '手绘 / 3D 地图',
  'advanced_stats': '高级运动数据',
  'ai_coach_unlimited': 'AI 教练不限次',
  'exclusive_skins': '专属领地皮肤',
  'hd_replay_export': '高清回放导出',
  'crew_tools': '跑团管理工具',
};

/// 会员：套餐、下单、轮询订单、自动续费开关。未成年不展示付费入口。
class MembershipPage extends ConsumerStatefulWidget {
  const MembershipPage({super.key});
  @override
  ConsumerState<MembershipPage> createState() => _MembershipPageState();
}

class _MembershipPageState extends ConsumerState<MembershipPage> {
  String? _plan;
  String? _channel;
  bool _paying = false;
  String? _status;
  bool _restoring = false;

  List<String> _channels() => ref.read(paymentServiceProvider).channels(ref.read(featuresProvider).value);

  /// 恢复购买 (App Store): re-verifies the user's transactions with the server.
  Future<void> _restore() async {
    setState(() => _restoring = true);
    final n = await runGuarded(context, () => ref.read(paymentServiceProvider).restoreApple());
    if (!mounted) return;
    setState(() => _restoring = false);
    if (n == null) return;
    await ref.read(authProvider.notifier).refreshUser();
    ref.invalidate(membershipProvider);
    if (mounted) toast(context, n > 0 ? '已恢复 $n 笔购买' : '没有可恢复的购买记录');
  }

  Future<void> _buy(Plan p) async {
    final all = _channels();
    if (all.isEmpty) return;
    final channel = all.contains(_channel) ? _channel! : all.first;
    setState(() {
      _paying = true;
      _status = '正在创建订单…';
    });
    try {
      setState(() => _status = '等待支付结果…');
      final o = await ref.read(paymentServiceProvider).purchase(p, channel);
      if (!mounted) return;
      if (o.isPaid) {
        await ref.read(authProvider.notifier).refreshUser();
        ref.invalidate(membershipProvider);
        if (mounted) toast(context, '开通成功，欢迎成为会员');
        setState(() => _status = null);
      } else {
        setState(() => _status = '订单 ${o.orderNo} 状态：${_orderStatus(o.status)}。支付结果以服务端为准，稍后可下拉刷新查看。');
      }
    } catch (e) {
      final ex = ApiException.from(e);
      if (mounted) {
        setState(() => _status = null);
        if (ex.code == 'realname_required') {
          toast(context, ex.message);
          context.push('/realname');
        } else if (ex.code != 'cancelled') {
          showError(context, ex);
        }
      }
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  String _orderStatus(String s) => switch (s) {
        'created' => '待支付',
        'paid' => '已支付',
        'refund_requested' => '退款申请中',
        'refunded' => '已退款',
        'closed' => '已关闭',
        'renew_failed' => '续费失败',
        _ => s,
      };

  Future<void> _toggleRenew(Membership m, bool v) async {
    if (!v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('关闭自动续费？'),
          content: Text('关闭后会员到期（${Fmt.date(m.expiresAt)}）不再扣费，权益保留到到期日。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('关闭')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final r = await runGuarded(context, () => ref.read(apiProvider).setAutoRenew(v));
    if (r != null) {
      ref.invalidate(membershipProvider);
      ref.read(authProvider.notifier).refreshUser().ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final channels = ref.watch(paymentServiceProvider).channels(ref.watch(featuresProvider).value);
    if (!channels.contains(_channel)) _channel = channels.firstOrNull;
    if (user?.isMinor == true) {
      return const Scaffold(
        body: SafeArea(
          child: Column(children: [
            BackHeader(title: '会员'),
            Expanded(child: Center(child: Text('未成年账号暂不提供付费服务', style: TextStyle(color: LL.text2)))),
          ]),
        ),
      );
    }
    final plans = ref.watch(plansProvider);
    final mem = ref.watch(membershipProvider).value ?? user?.membership;
    return Scaffold(
      body: SafeArea(
        child: SoundRefresh(
          onRefresh: () async {
            ref.invalidate(plansProvider);
            ref.invalidate(membershipProvider);
          },
          child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const BackHeader(title: '会员', subtitle: '只给体验类权益，花钱买不到抢地优势'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (mem != null && mem.active) _current(mem),
                const SizedBox(height: 12),
                AsyncBody<PlansResponse>(
                  value: plans,
                  onRetry: () => ref.invalidate(plansProvider),
                  data: (r) {
                    if (r.minorBlocked) {
                      return const LLCard(child: Text('未成年账号暂不提供付费服务', style: TextStyle(color: LL.text2)));
                    }
                    final sel = _plan ?? r.items.where((p) => p.recommended).firstOrNull?.code ?? r.items.firstOrNull?.code;
                    final plan = r.items.where((p) => p.code == sel).firstOrNull;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final p in r.items) _planTile(p, p.code == sel),
                      if (plan != null) ...[
                        const SizedBox(height: 12),
                        LLCard(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('会员权益', style: TextStyle(fontWeight: FontWeight.w900)),
                            const SizedBox(height: 8),
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              for (final e in plan.entitlements)
                                Chip(label: Text(entitlementNames[e] ?? e), backgroundColor: LL.card2, side: BorderSide.none),
                            ]),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        const Text('支付方式', style: TextStyle(color: LL.text2)),
                        if (channels.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('暂无可用的支付方式，请稍后再试', style: TextStyle(color: LL.text3)),
                          ),
                        RadioGroup<String>(
                          groupValue: _channel,
                          onChanged: (v) => setState(() => _channel = v),
                          child: Column(children: [
                            for (final c in channels)
                              RadioListTile<String>(
                                value: c,
                                contentPadding: EdgeInsets.zero,
                                title: Text(channelNames[c] ?? c),
                              ),
                          ]),
                        ),
                        if (plan.autoRenew)
                          const Text('连续包月到期自动续费，扣费前 5 天站内信提醒，可随时在本页一键关闭。',
                              style: TextStyle(color: LL.text3, fontSize: 12)),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _paying || channels.isEmpty ? null : () => _buy(plan),
                          child: _paying
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                              : Text('立即开通 ${Fmt.yuan(plan.firstPriceFen ?? plan.priceFen)}'),
                        ),
                        if (_status != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(_status!, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2)),
                          ),
                        if (channels.contains('apple_iap'))
                          Center(
                            child: TextButton(
                              onPressed: _restoring || _paying ? null : _restore,
                              child: Text(_restoring ? '正在恢复…' : '恢复购买'),
                            ),
                          ),
                      ],
                    ]);
                  },
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _current(Membership m) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m.planName ?? '会员', style: const TextStyle(color: LL.ink, fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text('到期 ${Fmt.date(m.expiresAt)}', style: const TextStyle(color: Color(0xFF3A3F1A))),
        if (m.autoRenew && m.nextChargeAt != null)
          Text('下次扣费 ${Fmt.date(m.nextChargeAt)}', style: const TextStyle(color: Color(0xFF3A3F1A))),
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(child: Text('自动续费', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w800))),
          if (m.isApple)
            const Text('请在 App Store 中管理', style: TextStyle(color: Color(0xFF3A3F1A), fontSize: 12))
          else
            Switch(
              value: m.autoRenew,
              onChanged: (v) => _toggleRenew(m, v),
              activeTrackColor: LL.ink,
              activeThumbColor: LL.lime,
            ),
        ]),
      ]),
    );
  }

  Widget _planTile(Plan p, bool selected) {
    final price = p.firstPriceFen != null && p.firstPriceFen != p.priceFen
        ? '首期 ${Fmt.yuan(p.firstPriceFen!)}，续费 ${Fmt.yuan(p.renewPriceFen ?? p.priceFen)}/${p.periodText}'
        : '${Fmt.yuan(p.priceFen)} / ${p.periodText}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => setState(() => _plan = p.code),
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1E2112) : LL.card,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: selected ? LL.lime : LL.border, width: selected ? 1.5 : 1),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  if (p.recommended) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: LL.orange, borderRadius: BorderRadius.circular(10)),
                      child: const Text('推荐', style: TextStyle(color: LL.ink, fontSize: 11, fontWeight: FontWeight.w800)),
                    ),
                  ],
                  if (p.seats > 1) ...[const SizedBox(width: 8), Text('${p.seats} 人', style: const TextStyle(color: LL.text2))],
                ]),
                const SizedBox(height: 4),
                Text(price, style: const TextStyle(color: LL.text2, fontSize: 13)),
              ]),
            ),
            Text(Fmt.yuan(p.firstPriceFen ?? p.priceFen), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: LL.lime)),
          ]),
        ),
      ),
    );
  }
}
