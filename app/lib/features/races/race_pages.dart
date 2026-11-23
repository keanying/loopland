import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart' show CursorPager;
import '../../api/errors.dart';
import '../../api/gathering_api.dart';
import '../../api/gathering_models.dart';
import '../../auth/auth_controller.dart';
import '../../core/features.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../pay/payment_service.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';
import '../../widgets/cursor_list.dart';
import '../../widgets/l_icons.dart';
import '../community/gathering_providers.dart';
import '../community/gathering_widgets.dart';
import '../local/booking_flow.dart' show ChannelPicker, PayFlow;
import '../social/social_widgets.dart' show UserAvatar, mediaUrl, openProfile;

const _statuses = ['', 'signup', 'upcoming', 'running', 'finished'];
const _statusLabels = ['全部', '报名中', '即将开始', '进行中', '已结束'];

/// 赛事中心（D-12）：按状态列出线上赛 / 线下赛，城区联赛入口。
class RacesPage extends ConsumerStatefulWidget {
  const RacesPage({super.key});
  @override
  ConsumerState<RacesPage> createState() => _RacesPageState();
}

class _RacesPageState extends ConsumerState<RacesPage> {
  int _status = 1;
  late final CursorPager<Race> _pager =
      CursorPager((cursor) => ref.read(gatheringApiProvider).races(status: _statuses[_status], cursor: cursor));

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '赛事中心', subtitle: '线上赛 · 线下赛 · 城区联赛'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChipTabs(
              labels: _statusLabels,
              index: _status,
              onChanged: (i) {
                setState(() => _status = i);
                _pager.refresh();
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: CursorListView<Race>(
              pager: _pager,
              empty: '暂时没有${_status == 0 ? '' : _statusLabels[_status]}的赛事',
              header: [
                LLCard(
                  color: LL.lime,
                  onTap: () => context.push('/league'),
                  child: const Row(children: [
                    LIcon(LIcons.shieldMoon, color: LL.ink),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('城区联赛', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 16)),
                        Text('同城区跑团每周比拼新圈面积', style: TextStyle(color: Color(0xFF3A3F1A), fontSize: 13)),
                      ]),
                    ),
                    LIcon(LIcons.chevronRight, color: LL.ink),
                  ]),
                ),
                const SizedBox(height: 12),
              ],
              itemBuilder: (context, r, _) => RaceCard(race: r),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 赛事详情：封面、规则、距离、时间窗、穿戴设备要求、奖牌、排行榜、我的成绩；报名 / 取消。
class RaceDetailPage extends ConsumerStatefulWidget {
  const RaceDetailPage({super.key, required this.raceId});
  final int raceId;
  @override
  ConsumerState<RaceDetailPage> createState() => _RaceDetailPageState();
}

class _RaceDetailPageState extends ConsumerState<RaceDetailPage> {
  bool _busy = false;

  GatheringApi get _api => ref.read(gatheringApiProvider);

  Future<void> _act(Future<Race> Function() f, String done) async {
    setState(() => _busy = true);
    final r = await runGuarded(context, f);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(raceProvider(widget.raceId));
    ref.invalidate(communityHomeProvider);
    toast(context, done);
  }

  /// D-12 paid signup: pick a channel → `POST signup {channel}` (entry
  /// `pending_pay`) → pay → poll until `signed`.
  Future<void> _paidSignup(Race r) async {
    if (ref.read(userProvider)?.isMinor == true) {
      await PayFlow.minorNotice(context, '付费报名');
      return;
    }
    final channel = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: LL.card,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => RaceFeeSheet(race: r),
    );
    if (channel == null || !mounted) return;
    final pay = ref.read(paymentServiceProvider);
    setState(() => _busy = true);
    try {
      await pay.ensureChannelReady(channel);
      final s = await _api.signupPaidRace(r.id, channel);
      ref.invalidate(raceProvider(widget.raceId));
      var paid = s.race.myEntry?.status == 'signed';
      if (!paid) {
        final no = s.orderNo;
        if (no != null) {
          paid = (await pay.payOrder(no, channel, s.payParams)).isPaid;
        } else {
          // No order number in the response: let the SDK run, then ask the race.
          await pay.sdkPay(channel, s.payParams);
          paid = await _waitSigned(r.id);
        }
      }
      if (!mounted) return;
      ref.invalidate(raceProvider(widget.raceId));
      ref.invalidate(communityHomeProvider);
      toast(context, paid ? '报名成功，已支付 ${Fmt.yuan(r.feeAmt)}' : '支付结果确认中，稍后刷新查看；15 分钟内未支付自动取消');
    } catch (e) {
      final ex = ApiException.from(e);
      ref.invalidate(raceProvider(widget.raceId));
      if (mounted && !PayFlow.handleError(context, ex, what: '付费报名')) showError(context, ex);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _waitSigned(int id) async {
    for (var i = 0; i < 15; i++) {
      final r = await _api.race(id);
      if (r.myEntry?.status == 'signed') return true;
      if (r.myEntry == null) return false;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<void> _cancel(Race r) async {
    final e = r.myEntry;
    if (r.isPaid && e?.status == 'signed') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('取消报名？'),
          content: Text('报名费 ${Fmt.yuan(r.feeAmt)} 将原路退回，一般 1–3 个工作日到账。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('再想想')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('取消并退款')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await _act(() => _api.cancelRaceSignup(r.id), '已取消报名，报名费原路退回');
      return;
    }
    await _act(() => _api.cancelRaceSignup(r.id), '已取消报名');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(raceProvider(widget.raceId));
    final me = ref.watch(userProvider)?.id;
    return Scaffold(
      body: SafeArea(
        child: AsyncBody<Race>(
          value: async,
          onRetry: () => ref.invalidate(raceProvider(widget.raceId)),
          data: (r) => Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                BackHeader(title: r.isOnline ? '线上赛' : '线下赛', subtitle: r.statusName),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ClipRRect(borderRadius: BorderRadius.circular(LL.radius), child: RaceCover(race: r, height: 170)),
                    const SizedBox(height: 14),
                    Text(r.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      Tag(r.isOnline ? '线上赛' : '线下赛', color: r.isOnline ? LL.sky : LL.orange),
                      Tag(r.statusName, color: r.status == 'signup' || r.status == 'running' ? LL.lime : LL.card2),
                      Tag(sportName(r.sport)),
                      if (r.requiresWearable) const Tag('需穿戴设备', color: LL.yellow),
                    ]),
                    const SizedBox(height: 14),
                    if (r.myEntry != null) ...[_MyResult(race: r), const SizedBox(height: 12)],
                    LLCard(
                      child: Column(children: [
                        _Row(LIcons.ruler, '距离', '${Fmt.km(r.distanceM, digits: r.distanceM % 1000 == 0 ? 0 : 1)} km'),
                        _Row(LIcons.clock, '比赛时间', '${Fmt.dateTime(r.startTime)} – ${Fmt.dateTime(r.endTime)}'),
                        _Row(LIcons.userCheck, '报名截止', Fmt.dateTime(r.signupEndTime)),
                        if (r.place != null) _Row(LIcons.pin, '地点', r.place!.name),
                        _Row(LIcons.wallet, '报名费', r.isPaid ? Fmt.yuan(r.feeAmt) : '免费'),
                        _Row(LIcons.users, '名额',
                            '已报名 ${Fmt.thousands(r.signedCount)}${r.capacity > 0 ? ' / ${Fmt.thousands(r.capacity)}' : ''}'),
                      ]),
                    ),
                    const SectionHeader('规则'),
                    LLCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          r.isOnline
                              ? '比赛时间内，单次${sportName(r.sport)}距离达到 ${Fmt.km(r.distanceM, digits: 1)} km 即完赛（开始和结束都要在时间窗内）。成绩按距离折算到赛事距离，用时越短排名越靠前；只算第一次完赛。'
                              : '线下赛按现场成绩，由主办方在赛后标记完赛并发放奖牌。',
                          style: const TextStyle(height: 1.6),
                        ),
                        if (r.requiresWearable) ...[
                          const SizedBox(height: 10),
                          Container(
                            key: const Key('race_wearable'),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(color: LL.yellow.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                            child: const Row(children: [
                              LIcon(LIcons.watch, color: LL.yellow, size: 18),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text('本赛事要求穿戴设备（手表 / 手环）数据，只用手机记录的运动不计成绩。',
                                    style: TextStyle(fontSize: 13, height: 1.4)),
                              ),
                            ]),
                          ),
                        ],
                        if (r.description.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(r.description, style: const TextStyle(color: LL.text2, height: 1.6)),
                        ],
                      ]),
                    ),
                    if (r.medal != null) ...[
                      const SectionHeader('完赛奖牌'),
                      LLCard(
                        child: Row(children: [
                          _MedalImage(medal: r.medal!, obtained: r.myEntry?.finished ?? false),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(r.medal!.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                              const SizedBox(height: 4),
                              Text((r.myEntry?.finished ?? false) ? '已获得，可在图鉴的奖牌页查看' : '完赛后自动发放到图鉴的奖牌页',
                                  style: const TextStyle(color: LL.text2, fontSize: 13)),
                            ]),
                          ),
                        ]),
                      ),
                    ],
                    if (r.leaderboard.isNotEmpty || r.status == 'running' || r.status == 'finished') ...[
                      SectionHeader(r.isOnline ? '排行榜 · 用时' : '完赛名单'),
                      if (r.leaderboard.isEmpty)
                        const LLCard(child: Text('还没有人完赛', style: TextStyle(color: LL.text2)))
                      else
                        for (final e in r.leaderboard)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: LLCard(
                              color: e.user.id == me ? const Color(0xFF23271A) : null,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(children: [
                                SizedBox(
                                  width: 30,
                                  child: Text('${e.rank}',
                                      style: TextStyle(fontWeight: FontWeight.w900, color: e.rank <= 3 ? LL.lime : LL.text2)),
                                ),
                                UserAvatar(user: e.user, size: 36, onTap: () => openProfile(context, e.user)),
                                const SizedBox(width: 10),
                                Expanded(child: Text(e.user.id == me ? '${e.user.nickname}（我）' : e.user.nickname)),
                                Text(Fmt.duration(e.resultSec), style: const TextStyle(fontWeight: FontWeight.w900)),
                              ]),
                            ),
                          ),
                    ],
                  ]),
                ),
              ]),
            ),
            _actions(r),
          ]),
        ),
      ),
    );
  }

  Widget _actions(Race r) {
    final e = r.myEntry;
    final Widget button;
    if (r.canCancel && (e?.pendingPay ?? false)) {
      // The server reuses the unpaid order when signing up again.
      button = Row(children: [
        Expanded(
          child: OutlinedButton(
            key: const Key('race_cancel'),
            onPressed: _busy ? null : () => _cancel(r),
            child: const Text('取消报名'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton(
            key: const Key('race_repay'),
            onPressed: _busy ? null : () => _paidSignup(r),
            child: Text('继续支付 ${Fmt.yuan(r.feeAmt)}'),
          ),
        ),
      ]);
    } else if (r.canCancel) {
      button = OutlinedButton(
        key: const Key('race_cancel'),
        onPressed: _busy ? null : () => _cancel(r),
        child: Text(r.isPaid ? '取消报名并退款' : '取消报名'),
      );
    } else if (r.canSignup && r.isPaid) {
      button = FilledButton(
        key: const Key('race_signup'),
        onPressed: _busy ? null : () => _paidSignup(r),
        child: Text('报名 ${Fmt.yuan(r.feeAmt)}'),
      );
    } else if (r.canSignup) {
      button = FilledButton(
        key: const Key('race_signup'),
        onPressed: _busy ? null : () => _act(() => _api.signupRace(r.id), r.isOnline ? '报名成功，比赛时间内去跑吧' : '报名成功'),
        child: const Text('立即报名（免费）'),
      );
    } else {
      final label = switch (r.status) {
        _ when e?.finished ?? false => '已完赛',
        _ when e != null && r.status == 'running' => r.isOnline ? '比赛进行中，去跑一次吧' : '比赛进行中',
        'signup' => '名额已满',
        'upcoming' => '报名已截止',
        'running' => '比赛进行中',
        'cancelled' => '赛事已取消',
        _ => '已结束',
      };
      button = e != null && r.status == 'running' && r.isOnline
          ? FilledButton(onPressed: () => context.go('/start'), child: Text(label))
          : FilledButton(onPressed: null, child: Text(label));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: LL.border))),
      child: SizedBox(width: double.infinity, child: button),
    );
  }
}

class _MyResult extends StatelessWidget {
  const _MyResult({required this.race});
  final Race race;
  @override
  Widget build(BuildContext context) {
    final e = race.myEntry!;
    final (title, body, color) = switch (e.status) {
      'finished' => (
          '完赛 ${e.resultSec == null ? '' : Fmt.duration(e.resultSec!)}',
          [if (e.rank != null) '第 ${e.rank} 名', if (e.finishedAt != null) '${Fmt.dateTime(e.finishedAt)} 完成'].join(' · '),
          LL.lime,
        ),
      'dnf' => ('未完赛', '比赛时间内没有完成规定距离', LL.card2),
      'pending_pay' => ('待支付', '报名费 ${Fmt.yuan(race.feeAmt)}，15 分钟内未支付自动取消报名', LL.yellow),
      _ => (
          '已报名',
          race.isOnline ? '在比赛时间内完成一次 ≥ ${Fmt.km(race.distanceM, digits: 1)} km 的${sportName(race.sport)}即可完赛' : '按时到场参赛',
          LL.sky,
        ),
    };
    final dark = color != LL.card2;
    return Container(
      key: const Key('race_my_entry'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(LL.radius)),
      child: Row(children: [
        LIcon(e.finished ? LIcons.trophy : LIcons.userCheck, color: dark ? LL.ink : LL.text, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('我的成绩 · $title',
                style: TextStyle(color: dark ? LL.ink : LL.text, fontWeight: FontWeight.w900, fontSize: 17)),
            if (body.isNotEmpty)
              Text(body, style: TextStyle(color: dark ? const Color(0xFF2A2F14) : LL.text2, fontSize: 13)),
          ]),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, this.value);
  final LGlyph icon;
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          LIcon(icon, size: 18, color: LL.text3),
          const SizedBox(width: 8),
          SizedBox(width: 68, child: Text(label, style: const TextStyle(color: LL.text3))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

class _MedalImage extends StatelessWidget {
  const _MedalImage({required this.medal, required this.obtained});
  final RaceMedal medal;
  final bool obtained;
  @override
  Widget build(BuildContext context) {
    final art = MedalArt(obtained: obtained, width: 64, label: medal.name);
    final u = medal.imageUrl;
    if (u == null) return art;
    return SizedBox(
      width: 64,
      height: 77,
      child: Image.network(mediaUrl(u), fit: BoxFit.contain, errorBuilder: (_, _, _) => art),
    );
  }
}

/// 报名费确认（D-12）：金额、退款规则、支付方式（微信 / 支付宝，iOS 同样）。
/// Pops with the chosen channel.
class RaceFeeSheet extends ConsumerStatefulWidget {
  const RaceFeeSheet({super.key, required this.race});
  final Race race;
  @override
  ConsumerState<RaceFeeSheet> createState() => _RaceFeeSheetState();
}

class _RaceFeeSheetState extends ConsumerState<RaceFeeSheet> {
  String? _channel;
  @override
  Widget build(BuildContext context) {
    final r = widget.race;
    final channels = ref.watch(paymentServiceProvider).serviceChannels(ref.watch(featuresProvider).value);
    if (!channels.contains(_channel)) _channel = channels.firstOrNull;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('报名缴费', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          LLCard(
            color: LL.card2,
            child: Row(children: [
              Expanded(child: Text(r.title, style: const TextStyle(fontWeight: FontWeight.w800))),
              Text(Fmt.yuan(r.feeAmt), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: LL.lime)),
            ]),
          ),
          const SizedBox(height: 10),
          const Text('报名即下单，15 分钟内未支付自动取消。比赛开始前取消报名，报名费原路退回；赛事被取消时自动退款。',
              style: TextStyle(color: LL.text3, fontSize: 12, height: 1.5)),
          const SizedBox(height: 8),
          const Text('支付方式', style: TextStyle(color: LL.text2)),
          ChannelPicker(channels: channels, value: _channel, onChanged: (c) => setState(() => _channel = c)),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('race_pay'),
            onPressed: _channel == null ? null : () => Navigator.pop(context, _channel),
            child: Text('支付 ${Fmt.yuan(r.feeAmt)}'),
          ),
        ]),
      ),
    );
  }
}
