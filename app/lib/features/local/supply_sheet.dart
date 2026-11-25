// A-16 补给站: bottom sheet for a tapped supply station on the map. 「领取」
// checks my position against the station radius, then
// POST /v1/drops/{id}/claim. Pops with the updated [MapSupply] (claimed
// today) so the map can dim the marker.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/perks_api.dart';
import '../../api/perks_models.dart';
import '../../claim/geo.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../widgets/cosmetics.dart';
import '../../widgets/l_icons.dart';
import '../play/locate.dart';
import 'coupons_pages.dart';

class SupplySheet extends ConsumerStatefulWidget {
  const SupplySheet({super.key, required this.supply, this.myLocation});
  final MapSupply supply;

  /// Last known position (from the map), for the initial distance hint.
  final LatLng? myLocation;
  @override
  ConsumerState<SupplySheet> createState() => _SupplySheetState();
}

class _SupplySheetState extends ConsumerState<SupplySheet> {
  late MapSupply _s = widget.supply;
  late LatLng? _at = widget.myLocation;
  bool _busy = false;
  String? _message;
  Coupon? _coupon;

  /// Metres outside the radius (≤ 0 = inside); null without a position.
  double? get _far => _at == null ? null : haversine(_s.center, _at!) - _s.radiusM;

  Future<void> _claim() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final at = await currentLocation(context, ref);
      if (at == null || !mounted) return;
      setState(() => _at = at);
      final far = _far!;
      if (far > 0) {
        setState(() => _message = '离补给站还有 ${distanceText(far)}，走到 ${_s.radiusM.round()} 米内再领取');
        return;
      }
      final c = await ref.read(perksApiProvider).claimDrop(_s.id, at);
      // 卡券包 / 联名活动 counts.
      ref.read(refreshProvider).afterCouponChange();
      if (!mounted) return;
      setState(() {
        _coupon = c;
        _s = _s.copyWith(claimedToday: true);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _message = switch (e.code) {
          'too_far' => '不在补给站范围内，走到 ${_s.radiusM.round()} 米内再领取',
          'already_claimed' => '今天已经领过这里的券了，明天再来',
          'sold_out' => '今天的券已经发完了，明天再来',
          _ => e.message,
        };
        if (e.code == 'already_claimed') _s = _s.copyWith(claimedToday: true);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final c = _coupon;
    final far = _far;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: CustomPaint(
              size: const Size(76, 76),
              painter: _SupplyIconPainter(claimed: s.claimedToday && c == null),
            ),
          ),
          const SizedBox(height: 10),
          Text(s.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          Text(c == null ? s.perkTitle : '领到「${c.perk.title}」！',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c == null ? LL.pink : LL.lime)),
          const SizedBox(height: 8),
          if (c != null)
            CouponCard(coupon: c, compact: true, onTap: () {
              Navigator.pop(context, s);
              openCoupon(context, c);
            })
          else
            Text(
              s.claimedToday
                  ? '今天已经领过了，明天再来。券在「卡券包」里。'
                  : '跑步轨迹经过 ${s.radiusM.round()} 米范围会自动领取；人在范围内也可以点「领取」。每人每天 1 张，到店出示二维码核销。'
                      '${far == null ? '' : far > 0 ? '\n你离这里还有 ${distanceText(far)}。' : '\n你已经在范围内。'}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: LL.text2, height: 1.5),
            ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Text(_message!, textAlign: TextAlign.center, style: const TextStyle(color: LL.orange)),
          ],
          const SizedBox(height: 18),
          if (c != null) ...[
            FilledButton(
              onPressed: () {
                Navigator.pop(context, s);
                context.push('/me/coupons');
              },
              child: const Text('去卡券包看看'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.pop(context, s), child: const Text('好的')),
          ] else if (s.claimedToday)
            OutlinedButton(
              onPressed: () {
                Navigator.pop(context, s);
                context.push('/me/coupons');
              },
              child: const Text('查看卡券包'),
            )
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: LL.pink, foregroundColor: LL.ink),
              onPressed: _busy ? null : _claim,
              icon: const LIcon(LIcons.gift),
              label: Text(_busy ? '正在确认位置…' : '领取'),
            ),
        ]),
      ),
    );
  }
}

class _SupplyIconPainter extends CustomPainter {
  _SupplyIconPainter({required this.claimed});
  final bool claimed;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (!claimed) canvas.drawCircle(c, size.width / 2, Paint()..color = LL.pink.withValues(alpha: 0.2));
    paintSupply(canvas, c, claimed: claimed, r: size.width * 0.3);
  }

  @override
  bool shouldRepaint(covariant _SupplyIconPainter old) => old.claimed != claimed;
}
