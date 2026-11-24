import 'package:material_ui/material_ui.dart';

import '../api/community_common.dart';
import '../api/errors.dart';
import '../core/theme.dart';
import 'common.dart';
import 'sound_refresh.dart';

/// Infinite list over a [CursorPager]: pull to refresh, loads the next page
/// near the bottom, spinner / error-with-retry / empty states.
///
/// The pager is owned by the caller (create it in `initState`, dispose it).
/// The first page is requested automatically when nothing was loaded yet.
class CursorListView<T> extends StatefulWidget {
  const CursorListView({
    super.key,
    required this.pager,
    required this.itemBuilder,
    this.empty = '这里还没有内容',
    this.header = const [],
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
    this.separator = 12,
    this.reverse = false,
    this.controller,
    this.emptyWidget,
  });

  final CursorPager<T> pager;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final String empty;
  final Widget? emptyWidget;

  /// Widgets above the items (scroll with the list).
  final List<Widget> header;
  final EdgeInsetsGeometry padding;
  final double separator;

  /// Chat-style lists (newest at the bottom, older pages load upward).
  final bool reverse;
  final ScrollController? controller;

  @override
  State<CursorListView<T>> createState() => _CursorListViewState<T>();
}

class _CursorListViewState<T> extends State<CursorListView<T>> {
  @override
  void initState() {
    super.initState();
    widget.pager.addListener(_changed);
    final p = widget.pager;
    if (p.items.isEmpty && !p.loading && p.error == null) p.refresh();
  }

  @override
  void didUpdateWidget(covariant CursorListView<T> old) {
    super.didUpdateWidget(old);
    if (old.pager != widget.pager) {
      old.pager.removeListener(_changed);
      widget.pager.addListener(_changed);
      if (widget.pager.items.isEmpty && !widget.pager.loading) widget.pager.refresh();
    }
  }

  @override
  void dispose() {
    widget.pager.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 600) widget.pager.loadMore();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pager;
    final items = p.items;
    final h = widget.header;
    Widget footer() {
      if (p.error != null && items.isNotEmpty) {
        return Center(child: TextButton(onPressed: p.loadMore, child: Text('${errorTextShort(p.error!)}，点此重试')));
      }
      if (p.loading && items.isNotEmpty) {
        return const Center(
            child: Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))));
      }
      if (!p.hasMore && items.isNotEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: Text('没有更多了', style: TextStyle(color: LL.text3, fontSize: 12))),
        );
      }
      return const SizedBox(height: 16);
    }

    Widget body() {
      if (items.isEmpty) {
        if (p.error != null) return ErrorBox(error: p.error!, onRetry: p.refresh);
        if (p.initialLoading) {
          return const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()));
        }
        return widget.emptyWidget ??
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(child: Text(widget.empty, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2))),
            );
      }
      return const SizedBox.shrink();
    }

    final count = h.length + (items.isEmpty ? 1 : items.length) + 1;
    final list = ListView.builder(
      controller: widget.controller,
      reverse: widget.reverse,
      padding: widget.padding,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i < h.length) return h[i];
        final k = i - h.length;
        if (items.isEmpty) return k == 0 ? body() : const SizedBox.shrink();
        if (k == items.length) return footer();
        return Padding(
          padding: EdgeInsets.only(bottom: widget.separator),
          child: widget.itemBuilder(context, items[k], k),
        );
      },
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.reverse ? list : SoundRefresh(onRefresh: p.refresh, child: list),
    );
  }
}

String errorTextShort(Object e) {
  final t = errorText(e);
  return t.length > 20 ? '加载失败' : t;
}
