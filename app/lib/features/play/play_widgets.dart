import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../widgets/l_icons.dart';

/// "05:42:10", or "2 天 05:42" when more than a day is left.
String formatCountdown(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours % 24, m = d.inMinutes % 60, s = d.inSeconds % 60;
  if (d.inDays > 0) return '${d.inDays} 天 ${two(h)}:${two(m)}';
  return '${two(d.inHours)}:${two(m)}:${two(s)}';
}

/// Rebuilds every second with the time left until [until].
class Countdown extends StatefulWidget {
  const Countdown({super.key, required this.until, required this.builder, this.onDone});
  final DateTime? until;
  final Widget Function(BuildContext context, Duration left) builder;
  final VoidCallback? onDone;

  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
  Timer? _t;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!_done && _left <= Duration.zero && widget.until != null) {
        _done = true;
        widget.onDone?.call();
      }
    });
  }

  @override
  void didUpdateWidget(covariant Countdown old) {
    super.didUpdateWidget(old);
    if (old.until != widget.until) _done = false;
  }

  Duration get _left => widget.until == null ? Duration.zero : widget.until!.difference(DateTime.now());

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _left.isNegative ? Duration.zero : _left);
}

/// Orange timer pill used on the boss page.
class TimerPill extends StatelessWidget {
  const TimerPill({super.key, required this.until, this.color = LL.orange});
  final DateTime? until;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF2A1A14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFF6A3D)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          LIcon(LIcons.timer, size: 16, color: color),
          const SizedBox(width: 6),
          Countdown(
            until: until,
            builder: (_, left) => Text(formatCountdown(left),
                style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14, fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ]),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
          ?trailing,
        ]),
      );
}

/// Small rounded label.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = LL.card2, this.fg = LL.text2});
  final String text;
  final Color color, fg;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w800)),
      );
}

/// Rank row: "1  (A) 阿杰 ........ 1,200".
class RankRow extends StatelessWidget {
  const RankRow({super.key, required this.rank, required this.name, required this.value, this.highlight = false, this.sub});
  final int rank;
  final String name, value;
  final String? sub;
  final bool highlight;
  static const _colors = [LL.lime, LL.lavender, LL.pink, LL.sky, LL.yellow, LL.orange];
  @override
  Widget build(BuildContext context) {
    return Container(
      height: sub == null ? 44 : 52,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: highlight ? const Color(0xFF2B3014) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: highlight ? Border.all(color: LL.lime.withValues(alpha: 0.6)) : null,
      ),
      child: Row(children: [
        SizedBox(
          width: 26,
          child: Text('$rank',
              style: TextStyle(fontWeight: FontWeight.w900, color: rank <= 3 ? LL.lime : LL.text2, fontSize: 13)),
        ),
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: _colors[(rank - 1).abs() % _colors.length], shape: BoxShape.circle),
          child: Text(name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1)),
              style: const TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            if (sub != null) Text(sub!, style: const TextStyle(color: LL.text3, fontSize: 11)),
          ]),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
      ]),
    );
  }
}

/// "6 天后结束" style range text.
String periodText(DateTime? from, DateTime? to) {
  String d(DateTime t) {
    final l = t.toLocal();
    return '${l.month.toString().padLeft(2, '0')}.${l.day.toString().padLeft(2, '0')}';
  }

  if (from == null && to == null) return '';
  if (from == null) return '截至 ${d(to!)}';
  if (to == null) return '${d(from)} 起';
  return '${d(from)} – ${d(to)}';
}
