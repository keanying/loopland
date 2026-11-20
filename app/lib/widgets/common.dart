import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../api/errors.dart';
import '../core/theme.dart';

void showError(BuildContext context, Object e) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(errorText(e))));
}

void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(msg)));
}

/// Rounded dark card.
class LLCard extends StatelessWidget {
  const LLCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color, this.onTap, this.border = true, this.radius = LL.radius});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;
  final bool border;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return Material(
      color: color ?? LL.card,
      shape: RoundedRectangleBorder(
          borderRadius: r, side: border && color == null ? const BorderSide(color: LL.border) : BorderSide.none),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// Pill-shaped segmented control (全城 / 我的 / 跑团 …).
class PillTabs extends StatelessWidget {
  const PillTabs({super.key, required this.labels, required this.index, required this.onChanged, this.expand = true});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (var i = 0; i < labels.length; i++)
        _tab(i),
    ];
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: LL.card.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(26)),
      child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: items),
    );
  }

  Widget _tab(int i) {
    final sel = i == index;
    final w = GestureDetector(
      onTap: () => onChanged(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: sel ? LL.text : Colors.transparent, borderRadius: BorderRadius.circular(20)),
        child: Text(labels[i],
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: sel ? LL.ink : LL.text2)),
      ),
    );
    return expand ? Expanded(child: w) : w;
  }
}

/// Chip-style tabs that scroll horizontally (图鉴分类).
class ChipTabs extends StatelessWidget {
  const ChipTabs({super.key, required this.labels, required this.index, required this.onChanged, this.trailing});
  final List<String> labels;
  final List<String>? trailing;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: labels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final sel = i == index;
          return GestureDetector(
            onTap: () => onChanged(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: sel ? LL.lime : LL.card, borderRadius: BorderRadius.circular(20)),
              child: Row(children: [
                Text(labels[i],
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: sel ? LL.ink : LL.text)),
                if (trailing != null && trailing![i].isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(trailing![i],
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: (sel ? LL.ink : LL.text).withValues(alpha: 0.7))),
                ],
              ]),
            ),
          );
        },
      ),
    );
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, this.onTap, this.size = 48, this.color = LL.card, this.fg = LL.text, this.badge = false, this.tooltip});
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final Color color;
  final Color fg;
  final bool badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final b = Material(
      color: color,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(alignment: Alignment.center, children: [
            Icon(icon, color: fg, size: size * 0.46),
            if (badge)
              Positioned(
                right: size * 0.22,
                top: size * 0.2,
                child: Container(width: 9, height: 9, decoration: const BoxDecoration(color: LL.red, shape: BoxShape.circle)),
              ),
          ]),
        ),
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

class BackHeader extends StatelessWidget {
  const BackHeader({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(children: [
        RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, onTap: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
            if (subtitle != null) Text(subtitle!, style: const TextStyle(color: LL.text2, fontSize: 13)),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 1)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, style: const TextStyle(color: LL.text2, fontSize: 13)),
              ),
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

class EnergyBadge extends StatelessWidget {
  const EnergyBadge({super.key, required this.energy});
  final int energy;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(color: LL.card, borderRadius: BorderRadius.circular(24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.bolt_rounded, color: LL.yellow, size: 20),
        const SizedBox(width: 4),
        Text(_fmt(energy), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ]),
    );
  }

  static String _fmt(int v) => v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
}

class LLProgress extends StatelessWidget {
  const LLProgress({super.key, required this.value, this.color = LL.lime, this.bg = LL.card2, this.height = 8});
  final double value;
  final Color color;
  final Color bg;
  final double height;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: bg)),
          FractionallySizedBox(widthFactor: value.clamp(0.0, 1.0), child: ColoredBox(color: color, child: SizedBox(height: height))),
        ]),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 48, this.color = LL.lavender});
  final String name;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final ch = name.isEmpty ? '?' : String.fromCharCodes(name.runes.take(1));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(ch, style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: size * 0.42)),
    );
  }
}

class StatBox extends StatelessWidget {
  const StatBox({super.key, required this.value, required this.label, this.dark = false, this.unit});
  final String value;
  final String? unit;
  final String label;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    final fg = dark ? LL.ink : LL.text;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text.rich(TextSpan(children: [
        TextSpan(text: value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: fg)),
        if (unit != null) TextSpan(text: ' $unit', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
      ])),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 12, color: dark ? const Color(0xFF3A3F1A) : LL.text2)),
    ]);
  }
}

/// "即将开放" placeholder tile for V2 features.
class ComingSoon extends StatelessWidget {
  const ComingSoon({super.key, this.text = '即将开放'});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: LL.card2, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(fontSize: 11, color: LL.text2, fontWeight: FontWeight.w700)),
      );
}

/// Loading / error / data for an [AsyncValue], with a retry button.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.data, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T) data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: data,
      loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
      error: (e, _) => ErrorBox(error: e, onRetry: onRetry),
    );
  }
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off_rounded, color: LL.text3, size: 40),
          const SizedBox(height: 12),
          Text(errorText(error), textAlign: TextAlign.center, style: const TextStyle(color: LL.text2)),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ]),
      ),
    );
  }
}

/// Wraps an async action with a busy flag + error snackbar.
Future<T?> runGuarded<T>(BuildContext context, Future<T> Function() f) async {
  try {
    return await f();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}
