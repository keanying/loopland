import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/models.dart';
import '../../auth/auth_controller.dart';
import '../../claim/geo.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/l_icons.dart';
import '../../widgets/monster_art.dart';
import '../local/coupons_pages.dart';
import 'locate.dart';
import 'play_widgets.dart';

/// Bottom sheet for a tapped energy chest. Pops with `true` when the chest
/// is gone for this user (opened / already opened / expired) so the map can
/// drop the marker.
class ChestSheet extends ConsumerStatefulWidget {
  const ChestSheet({super.key, required this.chest});
  final MapChest chest;
  @override
  ConsumerState<ChestSheet> createState() => _ChestSheetState();
}

class _ChestSheetState extends ConsumerState<ChestSheet> {
  bool _busy = false;
  ChestOpenResult? _opened;
  String? _message;
  bool _gone = false;
  LatLng? _at;

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final at = _at = await currentLocation(context, ref);
      if (at == null || !mounted) return;
      final r = await ref.read(apiProvider).openChest(widget.chest.id, at);
      if (!mounted) return;
      setState(() {
        _opened = r;
        _gone = true;
      });
      ref.read(authProvider.notifier).refreshUser().ignore();
    } on ApiException catch (e) {
      if (!mounted) return;
      final here = _at;
      final far = here == null ? 0.0 : haversine(widget.chest.center, here) - widget.chest.radiusM;
      setState(() {
        _message = switch (e.code) {
          'out_of_range' => far > 0 ? '离宝箱还有 ${distanceText(far)}，走到 ${widget.chest.radiusM.round()} 米内再开' : e.message,
          'already_opened' => '这个宝箱你已经开过了',
          'chest_expired' => '宝箱已经消失了，明天 06:00 会刷新新的宝箱',
          _ => e.message,
        };
        _gone = e.code == 'already_opened' || e.code == 'chest_expired';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chest;
    final o = _opened;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CustomPaint(
                size: const Size(84, 84),
                painter: _ChestPainter(open: o != null),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              o == null
                  ? (c.isMerchant ? '${c.merchant?.name ?? '商户'}宝箱' : '能量宝箱')
                  : (o.coupon != null ? '开出「${o.coupon!.perk.title}」' : '+${o.energy} 能量'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: o == null ? LL.text : LL.yellow),
            ),
            const SizedBox(height: 6),
            // V2 batch 4 (A-16): merchant chests hold a coupon instead of energy.
            if (o == null && c.perk != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('宝箱里是「${c.perk!.title}」券，开启后放进卡券包',
                    textAlign: TextAlign.center, style: const TextStyle(color: LL.pink, fontWeight: FontWeight.w700)),
              ),
            if (o?.coupon != null) ...[
              CouponCard(coupon: o!.coupon!, compact: true, onTap: () {
                Navigator.pop(context, true);
                openCoupon(context, o.coupon!);
              }),
              const SizedBox(height: 6),
              const Text('已放进卡券包 · 到店出示二维码核销，核销当天要有运动记录',
                  textAlign: TextAlign.center, style: TextStyle(color: LL.text2, fontSize: 12)),
            ] else if (o == null)
              Countdown(
                until: c.expiresAt,
                builder: (_, left) => Text(
                  '跑步轨迹经过会自动开启，也可以走到 ${c.radiusM.round()} 米内手动打开 · ${formatCountdown(left)} 后消失',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: LL.text2, height: 1.5),
                ),
              )
            else
              Text(
                o.bonus ? '药剂师加成，能量翻倍！' : '宝箱能量不计入每日上限',
                textAlign: TextAlign.center,
                style: TextStyle(color: o.bonus ? LL.lime : LL.text2),
              ),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: LL.orange),
              ),
            ],
            const SizedBox(height: 18),
            if (o == null && !_gone)
              FilledButton.icon(
                onPressed: _busy ? null : _open,
                icon: const LIcon(LIcons.unlock),
                label: Text(_busy ? '正在确认位置…' : '打开宝箱'),
              )
            else
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('好的')),
          ],
        ),
      ),
    );
  }
}

class _ChestPainter extends CustomPainter {
  _ChestPainter({required this.open});
  final bool open;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (open) canvas.drawCircle(c, size.width / 2, Paint()..color = LL.yellow.withValues(alpha: 0.25));
    paintChest(canvas, c, size.width * 0.32);
  }

  @override
  bool shouldRepaint(covariant _ChestPainter old) => old.open != open;
}
