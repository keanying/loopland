import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/errors.dart';
import '../../api/local_api.dart';
import '../../api/local_models.dart';
import '../../api/perks_models.dart' show Coupon;
import '../../audio/audio.dart';
import '../../auth/auth_controller.dart';
import '../../core/format.dart';
import '../../core/refresh.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../community/place_picker.dart' show quietLocation;
import 'local_providers.dart';
import 'qr_scan_page.dart';
import 'venue_section.dart' show nearbyVenuesProvider;

/// 场馆签到（C-07）: by location (inside `checkin_radius_m`) or by the venue
/// QR code. Shows the result sheet and returns the result (null on failure).
class VenueCheckin {
  VenueCheckin._();

  static Future<CheckinResult?> byLocation(BuildContext context, WidgetRef ref, Venue venue) async {
    final at = await quietLocation(ref);
    if (!context.mounted) return null;
    if (at == null) {
      final scan = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('没有拿到定位'),
          content: const Text('定位签到需要位置权限。也可以扫场馆前台或球场边的圈圈二维码签到。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('扫码签到')),
          ],
        ),
      );
      if (scan == true && context.mounted) return byQr(context, ref);
      return null;
    }
    return _run(context, ref, venue.id, () => ref.read(localApiProvider).checkin(venue.id, at: at), venue: venue);
  }

  /// Opens the scanner; any venue code works (the code names the venue).
  static Future<CheckinResult?> byQr(BuildContext context, WidgetRef ref) async {
    final raw = await ref.read(qrScannerProvider)(context);
    if (raw == null || !context.mounted) return null;
    return byPayload(context, ref, raw);
  }

  /// Scanned text or universal link `https://<domain>/v/<content>`.
  static Future<CheckinResult?> byPayload(BuildContext context, WidgetRef ref, String raw) async {
    final qr = parseVenueQr(raw);
    if (qr == null) {
      toast(context, '这不是圈圈场馆二维码');
      return null;
    }
    return _run(context, ref, qr.venueId, () => ref.read(localApiProvider).checkin(qr.venueId, qr: qr.payload));
  }

  static Future<CheckinResult?> _run(BuildContext context, WidgetRef ref, int venueId, Future<CheckinResult> Function() f,
      {Venue? venue}) async {
    try {
      final r = await f();
      ref.read(audioProvider)
        ..play(Sounds.scanOk)
        ..haptic(HapticKind.medium);
      ref.invalidate(venueProvider(venueId));
      ref.invalidate(nearbyVenuesProvider);
      ref.read(refreshProvider).afterEnergyChange().ignore();
      if (context.mounted) await showCheckinResult(context, r, venue: venue);
      return r;
    } catch (e) {
      final ex = ApiException.from(e);
      if (!context.mounted) return null;
      final msg = switch (ex.code) {
        'checkin_not_allowed' => ex.serverMessage.isNotEmpty
            ? ex.serverMessage
            : '不在场馆签到范围内（${venue == null ? '' : '${venue.checkinRadiusM.round()} 米内'}），走近一点或扫场馆二维码',
        'rate_limited' => ex.serverMessage.isNotEmpty ? ex.serverMessage : '每天最多在 3 个场馆签到',
        _ => ex.message,
      };
      toast(context, msg);
      return null;
    }
  }
}

Future<void> showCheckinResult(BuildContext context, CheckinResult r, {Venue? venue}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LL.card,
      showDragHandle: true,
      builder: (c) => CheckinResultSheet(result: r, fallbackVenue: venue),
    );

/// 签到成功：能量、馆主积分、本周积分、馆主状态、据点券。
class CheckinResultSheet extends ConsumerWidget {
  const CheckinResultSheet({super.key, required this.result, this.fallbackVenue});
  final CheckinResult result;
  final Venue? fallbackVenue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = result;
    final v = r.venue ?? fallbackVenue;
    final me = ref.watch(userProvider);
    final owner = v?.owner;
    final iAmOwner = owner != null && owner.user.id == me?.id;
    final top = v == null || v.weekRank.isEmpty ? null : v.weekRank.first;
    final String ownerLine;
    if (iAmOwner) {
      ownerLine = '你是本周馆主，继续签到，争取下周连任';
    } else if (top != null && top.user.id != me?.id && top.points >= r.weekPoints) {
      ownerLine = '本周第一 ${top.user.nickname} ${top.points} 分，还差 ${top.points - r.weekPoints + 1} 分反超';
    } else if (top != null) {
      ownerLine = '你暂列本周第一，保持到周日，下周就是馆主';
    } else {
      ownerLine = '${owner == null ? '本周还没有馆主。' : '本周馆主 ${owner.user.nickname}。'}周一 00:00 本周积分第一的人成为下周馆主';
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const LIcon(LIcons.verified, color: LL.lime, size: 56),
          const SizedBox(height: 6),
          const Text('签到成功', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
          if (v != null) Text(v.name, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _stat('+${r.energy}', '能量', LL.lime)),
            const SizedBox(width: 10),
            Expanded(child: _stat('+${r.points}', '馆主积分', LL.lavender)),
            const SizedBox(width: 10),
            Expanded(child: _stat('${r.weekPoints}', '本周积分', LL.sky)),
          ]),
          const SizedBox(height: 12),
          LLCard(
            color: LL.card2,
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const LIcon(LIcons.trophy, color: LL.yellow),
              const SizedBox(width: 10),
              Expanded(child: Text(ownerLine, style: const TextStyle(height: 1.4))),
            ]),
          ),
          if (r.coupon != null) ...[
            const SizedBox(height: 12),
            CheckinCouponCard(coupon: r.coupon!, onOpen: () {
              Navigator.pop(context);
              context.push('/me/coupons');
            }),
          ],
          const SizedBox(height: 16),
          Row(children: [
            if (v != null)
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    context.push('/venues/${v.id}');
                  },
                  child: const Text('馆主榜'),
                ),
              ),
            if (v != null) const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('好的'))),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String value, String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Column(children: [
          Text(value, style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.w900)),
          Text(label, style: const TextStyle(color: LL.text2, fontSize: 12)),
        ]),
      );
}

/// The stronghold coupon won by a check-in; opens the wallet.
class CheckinCouponCard extends StatelessWidget {
  const CheckinCouponCard({super.key, required this.coupon, required this.onOpen});
  final Coupon coupon;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final c = coupon;
    return Material(
      key: const Key('checkin_coupon'),
      color: LL.pink,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: LL.ink, borderRadius: BorderRadius.circular(16)),
              child: Text(c.perk.valueText.isEmpty ? '券' : c.perk.valueText,
                  textAlign: TextAlign.center, style: const TextStyle(color: LL.pink, fontWeight: FontWeight.w900, fontSize: 16)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('据点福利 · ${c.merchant?.name ?? ''}', style: const TextStyle(color: Color(0xFF3A1A2A), fontSize: 12)),
                Text(c.perk.title, style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 16)),
                if (c.expiresAt != null)
                  Text('${Fmt.date(c.expiresAt)} 前有效 · 已放进卡券包', style: const TextStyle(color: Color(0xFF3A1A2A), fontSize: 12)),
              ]),
            ),
            const LIcon(LIcons.chevronRight, color: LL.ink),
          ]),
        ),
      ),
    );
  }
}
