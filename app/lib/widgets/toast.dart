import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'l_icons.dart';

/// 轻提示的类型：决定左边的图标和颜色。
enum ToastKind { info, success, warning, error }

/// 显示一条轻提示（替代底部 SnackBar）：从屏幕顶部滑下的深色圆角卡片，
/// 在所有页面、底部面板和弹窗之上；不拦截点击（下面的按钮照常能点），
/// 按字数停留 2–5 秒后自动收起。同一时间只显示一条，新的替换旧的。
void toast(BuildContext context, String message, {ToastKind kind = ToastKind.info}) =>
    toaster(context)(message, kind: kind);

/// 先拿到「显示提示」的函数，再关页面 / 弹窗后调用（关掉之后 context 已经失效）：
/// ```dart
/// final show = toaster(context);
/// Navigator.pop(context);
/// show('发布成功', kind: ToastKind.success);
/// ```
void Function(String message, {ToastKind kind}) toaster(BuildContext context) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  return (message, {kind = ToastKind.info}) {
    if (overlay == null || !overlay.mounted) return;
    _Toasts.show(overlay, message, kind);
  };
}

/// 立刻收起当前提示（测试和切页时用）。
void dismissToast() => _Toasts.dismiss();

abstract final class _Toasts {
  static OverlayEntry? _entry;
  static int _seq = 0;

  static void show(OverlayState overlay, String message, ToastKind kind) {
    dismiss();
    final id = ++_seq;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        key: ValueKey(id),
        message: message,
        kind: kind,
        onDone: () {
          if (identical(_entry, entry)) _entry = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final e = _entry;
    _entry = null;
    if (e != null && e.mounted) e.remove();
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({super.key, required this.message, required this.kind, required this.onDone});
  final String message;
  final ToastKind kind;
  final VoidCallback onDone;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  Timer? _hold;

  /// 停留时间：1.8 秒起，每个字多 60 毫秒，最多 5 秒。
  Duration get _holdFor => Duration(milliseconds: math.min(5000, 1800 + widget.message.length * 60));

  @override
  void initState() {
    super.initState();
    _c.forward();
    _hold = Timer(_holdFor, () async {
      if (!mounted) return;
      await _c.reverse();
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _c.dispose();
    super.dispose();
  }

  (LGlyph, Color) get _look => switch (widget.kind) {
        ToastKind.success => (LIcons.checkCircle, LL.lime),
        ToastKind.warning => (LIcons.alert, LL.orange),
        ToastKind.error => (LIcons.alert, LL.red),
        ToastKind.info => (LIcons.info, LL.lavender),
      };

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final (glyph, color) = _look;
    final anim = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return Positioned(
      left: 16,
      right: 16,
      top: top + 10,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, -0.6), end: Offset.zero).animate(anim),
            child: Center(
              child: Semantics(
                liveRegion: true,
                label: widget.message,
                excludeSemantics: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
                      decoration: BoxDecoration(
                        color: LL.card.withValues(alpha: 0.97),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: color.withValues(alpha: 0.35)),
                        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8))],
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
                          child: LIcon(glyph, size: 18, color: color),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            widget.message,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: LL.text, fontSize: 14, fontWeight: FontWeight.w600, height: 1.35),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
