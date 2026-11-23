import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/community_common.dart';
import '../../api/gathering_models.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';
import '../social/social_widgets.dart' show mediaUrl;

/// "今晚 19:30" / "明天 07:00" / "周六 07:00" / "11-28 07:00".
String whenText(DateTime? t, {DateTime? now}) {
  if (t == null) return '-';
  final l = t.toLocal();
  final n = (now ?? DateTime.now()).toLocal();
  final day = DateTime(l.year, l.month, l.day);
  final today = DateTime(n.year, n.month, n.day);
  final diff = day.difference(today).inDays;
  final hm = DateFormat('HH:mm').format(l);
  if (diff == 0) return '${l.hour >= 18 ? '今晚' : '今天'} $hm';
  if (diff == 1) return '明天 $hm';
  if (diff == 2) return '后天 $hm';
  if (diff > 2 && diff < 7) return '${const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][l.weekday - 1]} $hm';
  return '${DateFormat('MM-dd').format(l)} $hm';
}

/// "19:30–21:00" or "11-28 19:30 – 11-29 08:00" across days.
String timeRangeText(DateTime? a, DateTime? b) {
  if (a == null) return '-';
  if (b == null) return whenText(a);
  final la = a.toLocal(), lb = b.toLocal();
  final sameDay = la.year == lb.year && la.month == lb.month && la.day == lb.day;
  return sameDay ? '${whenText(a)}–${DateFormat('HH:mm').format(lb)}' : '${whenText(a)} – ${whenText(b)}';
}

Color meetupColor(String type) => switch (type) {
      'ball' => LL.pink,
      'ride' => LL.sky,
      _ => LL.lime,
    };

/// Network avatar with the letter avatar as placeholder / fallback.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.url, this.size = 44, this.color = LL.lavender});
  final String name;
  final String? url;
  final double size;
  final Color color;

  factory PersonAvatar.user(UserBrief? u, {double size = 44, Color color = LL.lavender}) =>
      PersonAvatar(name: u?.nickname ?? '?', url: u?.avatarUrl, size: size, color: color);

  @override
  Widget build(BuildContext context) {
    final letter = Avatar(name: name, size: size, color: color);
    final u = url;
    if (u == null || u.isEmpty) return letter;
    return ClipOval(
      child: Image.network(mediaUrl(u), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => letter),
    );
  }
}

/// Red unread count bubble.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.muted = false});
  final int count;
  final bool muted;
  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: muted ? LL.text3 : LL.red, borderRadius: BorderRadius.circular(10)),
      child: Text(count > 99 ? '99+' : '$count',
          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 0, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(color: LL.text2, fontSize: 15, fontWeight: FontWeight.w700))),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ]),
      );
}

/// Small rounded tag.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = LL.card2, this.fg});
  final String text;
  final Color color;
  final Color? fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, color: fg ?? (color == LL.card2 ? LL.text2 : LL.ink))),
      );
}

/// 「审核中」/「未通过」 marker for the author's own content.
class ReviewMark extends StatelessWidget {
  const ReviewMark({super.key, required this.status});
  final String status;
  @override
  Widget build(BuildContext context) => switch (status) {
        'pending' => const Tag('审核中', color: LL.yellow),
        'rejected' => const Tag('未通过', color: LL.red),
        _ => const SizedBox.shrink(),
      };
}

/// 组局 card (list / home). Matches the 组局 prototype: type tag, time,
/// title, place · distance, requirement chip, joined / capacity bar, action.
class MeetupCard extends StatelessWidget {
  const MeetupCard({super.key, required this.meetup, this.onJoin, this.busy = false});
  final Meetup meetup;
  final VoidCallback? onJoin;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final m = meetup;
    final color = meetupColor(m.type);
    final place = [
      if (m.place != null) m.place!.name,
      if (m.distanceM != null) Fmt.distance(m.distanceM!),
    ].join(' · ');
    final (label, enabled) = switch (m.status) {
      'cancelled' => ('已取消', false),
      'ended' => ('已结束', false),
      _ when m.joined => ('已报名', false),
      'full' => ('已满员', false),
      _ => ('加入', true),
    };
    return LLCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      onTap: () => context.push('/meetups/${m.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Tag(m.typeName, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(whenText(m.startTime), style: const TextStyle(color: LL.text2))),
          ReviewMark(status: m.reviewStatus),
        ]),
        const SizedBox(height: 10),
        Text(m.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        if (place.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(place, style: const TextStyle(color: LL.text2, fontSize: 13)),
        ],
        if (m.requirement.isNotEmpty) ...[
          const SizedBox(height: 8),
          Tag(m.requirement),
        ],
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LLProgress(value: m.capacity == 0 ? 0 : m.joinedCount / m.capacity, color: color, height: 6),
              const SizedBox(height: 6),
              Text('${m.joinedCount} / ${m.capacity} 人', style: const TextStyle(color: LL.text2, fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 16),
          if (onJoin != null)
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(76, 44)),
              onPressed: enabled && !busy ? onJoin : null,
              child: Text(label),
            )
          else
            Tag(label == '加入' ? m.district : label),
        ]),
      ]),
    );
  }
}

/// Compact 集结跑 row (community home).
class RallyBrief extends StatelessWidget {
  const RallyBrief({super.key, required this.rally, this.onTap});
  final Rally rally;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final r = rally;
    return LLCard(
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(color: LL.lavender, shape: BoxShape.circle),
          child: const LIcon(LIcons.run, color: LL.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            Text(
                '${whenText(r.startTime)} · ${r.place?.name ?? ''} · ${Fmt.km(r.distanceGoalM, digits: 1)} km',
                style: const TextStyle(color: LL.text2, fontSize: 13)),
          ]),
        ),
        if (r.bonusActive) const Tag('加成中', color: LL.lime) else Tag('${r.joinedCount} 人报名'),
      ]),
    );
  }
}

/// 赛事 card with cover, tags, distance and window.
class RaceCard extends StatelessWidget {
  const RaceCard({super.key, required this.race, this.compact = false});
  final Race race;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final r = race;
    return LLCard(
      padding: EdgeInsets.zero,
      onTap: () => context.push('/races/${r.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!compact) RaceCover(race: r, height: 120),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Tag(r.isOnline ? '线上赛' : '线下赛', color: r.isOnline ? LL.sky : LL.orange),
              const SizedBox(width: 8),
              Tag(r.statusName, color: r.status == 'signup' || r.status == 'running' ? LL.lime : LL.card2),
              if (r.isPaid) ...[const SizedBox(width: 8), Tag('报名 ${Fmt.yuan(r.feeAmt)}', color: LL.yellow)],
              const Spacer(),
              if (r.myEntry != null)
                Text(
                    switch (r.myEntry!.status) {
                      'finished' => '已完赛',
                      'dnf' => '未完赛',
                      'pending_pay' => '待支付',
                      _ => '已报名',
                    },
                    style: const TextStyle(color: LL.lime, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            Text(r.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text('${Fmt.km(r.distanceM, digits: r.distanceM % 1000 == 0 ? 0 : 1)} km · ${timeRangeText(r.startTime, r.endTime)}',
                style: const TextStyle(color: LL.text2, fontSize: 13)),
            if (!compact) ...[
              const SizedBox(height: 4),
              Text(
                  '已报名 ${Fmt.thousands(r.signedCount)}${r.capacity > 0 ? ' / ${Fmt.thousands(r.capacity)}' : ''}${r.medal != null ? ' · 完赛奖牌' : ''}',
                  style: const TextStyle(color: LL.text3, fontSize: 12)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Race cover image, or a brand gradient with the distance when missing.
class RaceCover extends StatelessWidget {
  const RaceCover({super.key, required this.race, this.height = 160});
  final Race race;
  final double height;
  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [LL.lavender, LL.sky], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      alignment: Alignment.bottomLeft,
      padding: const EdgeInsets.all(16),
      child: Text('${Fmt.km(race.distanceM, digits: 0)}K',
          style: const TextStyle(color: LL.ink, fontSize: 44, fontWeight: FontWeight.w900, letterSpacing: 1)),
    );
    final u = race.coverUrl;
    if (u == null) return fallback;
    return Image.network(mediaUrl(u), height: height, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback);
  }
}
