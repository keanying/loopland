// E-04 卡券包: /me/coupons (未使用 / 已使用 / 已过期) and the coupon detail
// with the rotating store QR (GET /v1/coupons/{id}/qr, 60 s valid, refreshed
// every 50 s).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/errors.dart';
import '../../api/perks_api.dart';
import '../../api/perks_models.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import 'perks_providers.dart';

String _md(DateTime? t) => t == null ? '-' : DateFormat('MM.dd').format(t.toLocal());
String _mdhm(DateTime? t) => t == null ? '-' : DateFormat('MM.dd HH:mm').format(t.toLocal());

/// Coupon colour by merchant (stable per merchant).
Color couponColor(Coupon c) {
  const colors = [LL.lime, LL.pink, LL.sky, LL.lavender, LL.yellow, LL.orange];
  return colors[(c.merchant?.id ?? c.id).abs() % colors.length];
}

/// 「8K2D 9QXW」.
String groupedCode(String code) {
  final b = StringBuffer();
  for (var i = 0; i < code.length; i++) {
    if (i > 0 && i % 4 == 0) b.write(' ');
    b.write(code[i]);
  }
  return b.toString();
}

/// The rule every coupon has (核销 needs a run today), shown even when the
/// perk's own rules text does not mention it.
const activityRule = '需要当天有一条运动记录：今天运动过（已结算的运动记录）才能核销';

/// Bought coupons (商品券, V2 batch 5) are redeemed without a run that day.
const productCouponRule = '购买的券到店出示即可核销，不需要当天有运动记录';

void openCoupon(BuildContext context, Coupon c) => context.push('/me/coupons/${c.id}', extra: c);

/// /me/coupons
class CouponsPage extends ConsumerStatefulWidget {
  const CouponsPage({super.key, this.initialStatus = 'unused'});
  final String initialStatus;
  @override
  ConsumerState<CouponsPage> createState() => _CouponsPageState();
}

class _CouponsPageState extends ConsumerState<CouponsPage> {
  late int _tab = couponStatuses.indexOf(widget.initialStatus).clamp(0, couponStatuses.length - 1);

  @override
  Widget build(BuildContext context) {
    final status = couponStatuses[_tab];
    final v = ref.watch(myCouponsProvider(status));
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const BackHeader(title: '卡券包', subtitle: '运动领的联名福利、买的团购券 · 到店出示二维码核销'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: PillTabs(labels: couponStatusNames, index: _tab, onChanged: (i) => setState(() => _tab = i)),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(myCouponsProvider(status).future),
              child: AsyncBody<List<Coupon>>(
                value: v,
                onRetry: () => ref.invalidate(myCouponsProvider(status)),
                data: (items) => items.isEmpty
                    ? ListView(children: [
                        const SizedBox(height: 80),
                        const LIcon(LIcons.ticket, color: LL.text3, size: 44),
                        const SizedBox(height: 12),
                        Text(
                          status == 'unused'
                              ? '还没有可用的券\n跑步经过补给站、开商户宝箱、到据点签到都能领\n场馆页的「团购 / 套餐」也能买'
                              : '这里还没有券',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: LL.text2, height: 1.6),
                        ),
                      ])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => CouponCard(coupon: items[i], onTap: () => openCoupon(context, items[i])),
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Ticket-shaped coupon row (wallet, settlement page).
class CouponCard extends StatelessWidget {
  const CouponCard({super.key, required this.coupon, this.onTap, this.compact = false});
  final Coupon coupon;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = coupon;
    final active = c.isUnused;
    final color = active ? couponColor(c) : LL.card2;
    final fg = active ? LL.ink : LL.text3;
    final sub = switch (c.status) {
      'unused' => '${c.isPass ? '${c.usesText} · ' : ''}有效期至 ${_md(c.expiresAt)}',
      'used' => '已于 ${_mdhm(c.usedAt)} 使用${c.usedStore == null ? '' : ' · ${c.usedStore}'}',
      'voided' => '已作废',
      'refunded' => '已退款 · 原路退回',
      _ => '已于 ${_md(c.expiresAt)} 过期',
    };
    return Semantics(
      button: onTap != null,
      label: '${c.merchant?.name ?? ''} ${c.perk.title}',
      child: Material(
        color: LL.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: LL.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: compact ? 82 : 96,
                color: color,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(c.perk.valueText.isEmpty ? '券' : c.perk.valueText,
                      style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: compact ? 20 : 24)),
                ),
              ),
              CustomPaint(size: const Size(1, double.infinity), painter: _PerforationPainter()),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(14, compact ? 10 : 14, 10, compact ? 10 : 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(c.perk.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: active ? LL.text : LL.text2)),
                    const SizedBox(height: 2),
                    Row(children: [
                      if (c.isProduct) ...[_BoughtTag(active: active), const SizedBox(width: 6)],
                      Flexible(
                        child: Text(c.merchant?.name ?? '',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LL.text2, fontSize: 13)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(sub, style: TextStyle(color: active ? LL.lime : LL.text3, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
              if (onTap != null)
                const Padding(
                  padding: EdgeInsets.only(right: 10),
                  child: LIcon(LIcons.chevronRight, color: LL.text3),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 「已购」: a coupon bought with money (商品券), not won by running.
class _BoughtTag extends StatelessWidget {
  const _BoughtTag({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context) => Container(
        key: const Key('coupon_bought'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: active ? LL.sky : LL.card2,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('已购', style: TextStyle(color: active ? LL.ink : LL.text3, fontSize: 11, fontWeight: FontWeight.w900)),
      );
}

class _PerforationPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = LL.border
      ..strokeWidth = 1.5;
    for (var y = 4.0; y < size.height; y += 8) {
      canvas.drawLine(Offset(0, y), Offset(0, y + 4), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// /me/coupons/:id. [coupon] comes from the list (route `extra`); a deep
/// link without it looks the coupon up in the three lists.
class CouponDetailPage extends ConsumerWidget {
  const CouponDetailPage({super.key, required this.couponId, this.coupon, this.clock});
  final int couponId;
  final Coupon? coupon;

  /// Tests inject a fake clock for the QR countdown.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = coupon;
    if (c != null) return _CouponDetail(coupon: c, clock: clock);
    final lists = [for (final s in couponStatuses) ref.watch(myCouponsProvider(s))];
    for (final l in lists) {
      final hit = l.value?.where((e) => e.id == couponId).firstOrNull;
      if (hit != null) return _CouponDetail(coupon: hit, clock: clock);
    }
    final err = lists.map((l) => l.error).nonNulls.firstOrNull;
    final loading = lists.any((l) => l.isLoading);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const BackHeader(title: '券详情'),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : err != null
                    ? ErrorBox(error: err, onRetry: () {
                        for (final s in couponStatuses) {
                          ref.invalidate(myCouponsProvider(s));
                        }
                      })
                    : const Center(child: Text('没有找到这张券', style: TextStyle(color: LL.text2))),
          ),
        ]),
      ),
    );
  }
}

class _CouponDetail extends StatelessWidget {
  const _CouponDetail({required this.coupon, this.clock});
  final Coupon coupon;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final c = coupon;
    final color = c.isUnused ? couponColor(c) : LL.card2;
    final fg = c.isUnused ? LL.ink : LL.text2;
    // Bought coupons (商品券) need no run on the day.
    final rules = [
      if (c.perk.rules.isNotEmpty) ...c.perk.rules.split(RegExp(r'[；;\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty),
      if (!c.isProduct && !c.perk.rules.contains('运动记录')) activityRule,
      if (c.isProduct) productCouponRule,
    ];
    final src = c.source;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          const BackHeader(title: '券详情'),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(28), border: Border.all(color: LL.border)),
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                color: color,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(c.merchant?.name ?? '', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(c.perk.title, style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 22)),
                      if (c.perk.description.isNotEmpty)
                        Text(c.perk.description, style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 13)),
                    ]),
                  ),
                  if (c.perk.valueText.isNotEmpty)
                    Text(c.perk.valueText, style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 30)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                child: c.isUnused
                    ? Column(children: [
                        CouponQrPanel(couponId: c.id, clock: clock),
                        if (c.isPass) ...[
                          const SizedBox(height: 10),
                          Text(c.usesText,
                              key: const Key('coupon_uses'),
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: LL.lime)),
                          const Text('每次核销用掉 1 次', style: TextStyle(color: LL.text3, fontSize: 12)),
                        ],
                        const SizedBox(height: 14),
                        const Text('券码', style: TextStyle(color: LL.text3, fontSize: 12)),
                        SelectableText(groupedCode(c.code),
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 2, fontFamily: 'Roboto')),
                        const SizedBox(height: 4),
                        const Text('到店出示二维码，由店员扫码核销；扫不出时报券码',
                            textAlign: TextAlign.center, style: TextStyle(color: LL.text2, fontSize: 12)),
                      ])
                    : Column(children: [
                        LIcon(c.status == 'used' ? LIcons.checkCircle : LIcons.history,
                            color: LL.text3, size: 40),
                        const SizedBox(height: 8),
                        Text(
                          switch (c.status) {
                            'used' => '已于 ${_mdhm(c.usedAt)}${c.usedStore == null ? '' : ' 在 ${c.usedStore} '}核销',
                            'voided' => '这张券已作废',
                            'refunded' => '这张券已退款，钱款原路退回',
                            _ => '已于 ${_md(c.expiresAt)} 过期',
                          },
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: LL.text2, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text('券码 ${groupedCode(c.code)}', style: const TextStyle(color: LL.text3, fontSize: 12)),
                      ]),
              ),
            ]),
          ),
          if (c.isUnused && !c.isProduct) ...[
            const SizedBox(height: 12),
            LLCard(
              color: const Color(0xFF26223A),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: const [
                LIcon(LIcons.run, color: LL.lavender),
                SizedBox(width: 10),
                Expanded(
                  child: Text('核销需要当天有一条运动记录，今天还没运动的话，先跑一圈再来',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 16),
          const Text('使用规则', style: TextStyle(color: LL.text2, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          LLCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final r in rules) _Bullet(r),
              _Bullet('有效期：${_md(c.obtainedAt)} – ${_md(c.expiresAt)}${c.perk.validDays > 0 ? '（${c.isProduct ? '购买' : '领取'}后 ${c.perk.validDays} 天内有效）' : ''}'),
              if (src != null && src.isProduct)
                _Bullet('来源：购买${src.name.isNotEmpty ? '「${src.name}」' : '的团购商品'}')
              else if (src != null)
                _Bullet('来源：${src.name.isNotEmpty ? src.name : dropTypeName(src.type)}'
                    '${src.name.isNotEmpty ? '（${dropTypeName(src.type)}）' : ''}'),
              const _Bullet('二维码 60 秒有效、自动刷新，截图转发无效；券不能转让、不能兑现'),
            ]),
          ),
          if (src != null && src.isProduct && src.orderId != null) ...[
            const SizedBox(height: 12),
            LLCard(
              key: const Key('coupon_order'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              onTap: () => context.push('/me/product-orders/${src.orderId}'),
              child: const Row(children: [
                LIcon(LIcons.receipt, color: LL.sky),
                SizedBox(width: 10),
                Expanded(child: Text('查看订单 · 未使用的券可在订单里退款', style: TextStyle(fontWeight: FontWeight.w700))),
                LIcon(LIcons.chevronRight, color: LL.text3),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 8),
            child: CircleAvatar(radius: 2.5, backgroundColor: LL.lime),
          ),
          Expanded(child: Text(text, style: const TextStyle(height: 1.5, fontSize: 14))),
        ]),
      );
}

/// The store QR: fetched from `GET /v1/coupons/{id}/qr`, valid
/// `expires_in_sec` (60 s), refreshed every [refreshEvery] (50 s) and when the
/// app comes back to the foreground. Shows a countdown to the next refresh.
class CouponQrPanel extends ConsumerStatefulWidget {
  const CouponQrPanel({super.key, required this.couponId, this.clock, this.refreshEvery = const Duration(seconds: 50), this.size = 210});
  final int couponId;
  final DateTime Function()? clock;
  final Duration refreshEvery;
  final double size;
  @override
  ConsumerState<CouponQrPanel> createState() => _CouponQrPanelState();
}

class _CouponQrPanelState extends ConsumerState<CouponQrPanel> with WidgetsBindingObserver {
  CouponQr? _qr;
  DateTime? _fetchedAt;
  Object? _error;
  bool _loading = false;
  Timer? _tick;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetch();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetch();
  }

  void _onTick() {
    if (!mounted) return;
    final at = _fetchedAt;
    if (!_loading && (at == null ? _error == null : _now().difference(at) >= widget.refreshEvery)) {
      _fetch();
    } else {
      setState(() {});
    }
  }

  Future<void> _fetch() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final q = await ref.read(perksApiProvider).couponQr(widget.couponId);
      if (!mounted) return;
      setState(() {
        _qr = q;
        _fetchedAt = _now();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _qr;
    final at = _fetchedAt;
    final now = _now();
    final expired = q == null || at == null || now.difference(at).inSeconds >= q.expiresInSec;
    final next = at == null ? 0 : (widget.refreshEvery - now.difference(at)).inSeconds.clamp(0, 999);
    final size = widget.size;
    Widget code;
    if (q == null) {
      code = SizedBox(
        width: size,
        height: size,
        child: Center(
          child: _error == null
              ? const CircularProgressIndicator(color: LL.ink)
              : Text(errorText(_error!), textAlign: TextAlign.center, style: const TextStyle(color: LL.ink)),
        ),
      );
    } else {
      code = Opacity(
        opacity: expired ? 0.15 : 1,
        child: QrImageView(
          key: ValueKey('qr:${q.payload}'),
          data: q.payload,
          size: size,
          padding: EdgeInsets.zero,
          backgroundColor: const Color(0xFFFFFFFF),
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          semanticsLabel: '券码二维码',
        ),
      );
    }
    final String status;
    if (_error != null && expired) {
      status = '二维码刷新失败 · 点二维码重试';
    } else if (_loading && expired) {
      status = '正在刷新…';
    } else if (expired) {
      status = '二维码已过期 · 点二维码刷新';
    } else {
      status = '$next 秒后自动刷新 · 截图无效';
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        onTap: _loading ? null : _fetch,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(20)),
          child: code,
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisSize: MainAxisSize.min, children: [
        LIcon(LIcons.refresh, size: 16, color: _error != null ? LL.orange : LL.lime),
        const SizedBox(width: 4),
        Text(status,
            style: TextStyle(color: _error != null ? LL.orange : LL.text2, fontSize: 13, fontWeight: FontWeight.w700)),
      ]),
    ]);
  }
}

/// Settlement page block: coupons won during this run (补给站 / 商户宝箱).
class SettlementCoupons extends StatelessWidget {
  const SettlementCoupons({super.key, required this.coupons});
  final List<Coupon> coupons;
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 0, 10),
        child: Row(children: [
          const Expanded(child: Text('联名福利', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
          TextButton(onPressed: () => context.push('/me/coupons'), child: const Text('卡券包')),
        ]),
      ),
      for (final c in coupons) ...[
        CouponCard(coupon: c, compact: true, onTap: () => openCoupon(context, c)),
        const SizedBox(height: 8),
      ],
      Text('本次运动经过补给站、开商户宝箱得到 ${coupons.length} 张券，已放进卡券包；核销时当天要有运动记录',
          style: const TextStyle(color: LL.text3, fontSize: 12)),
    ]);
  }
}
