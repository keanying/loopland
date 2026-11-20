import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// 站内消息：分类显示、标记已读。
class InboxPage extends ConsumerStatefulWidget {
  const InboxPage({super.key});
  @override
  ConsumerState<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends ConsumerState<InboxPage> {
  static const _cats = ['all', 'territory', 'system', 'interaction'];
  static const _names = ['全部', '领地', '系统', '互动'];
  int _cat = 0;
  List<InboxItem> _items = const [];
  int _unread = 0;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await ref.read(apiProvider).inbox(category: _cats[_cat]);
      if (!mounted) return;
      setState(() {
        _items = p.items;
        _unread = p.unread;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _readAll() async {
    final n = await runGuarded(context, () => ref.read(apiProvider).markRead(all: true));
    if (n == null || !mounted) return;
    setState(() {
      _unread = n;
      _items = [for (final i in _items) i.copyWith(read: true)];
    });
    ref.invalidate(inboxUnreadProvider);
  }

  Future<void> _open(InboxItem it) async {
    if (!it.read) {
      final n = await runGuarded(context, () => ref.read(apiProvider).markRead(ids: [it.id]));
      if (n != null && mounted) {
        setState(() {
          _unread = n;
          _items = [for (final i in _items) i.id == it.id ? i.copyWith(read: true) : i];
        });
        ref.invalidate(inboxUnreadProvider);
      }
    }
    if (!mounted) return;
    final tid = it.territoryId;
    if (tid != null) context.push('/city/$tid');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(
            title: '消息',
            subtitle: '$_unread 条未读',
            trailing: TextButton(onPressed: _unread == 0 ? null : _readAll, child: const Text('全部已读')),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ChipTabs(
              labels: _names,
              index: _cat,
              onChanged: (i) {
                setState(() => _cat = i);
                _load();
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _items.isEmpty
                    ? ErrorBox(error: _error!, onRetry: _load)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _items.isEmpty
                            ? ListView(children: const [
                                Padding(
                                  padding: EdgeInsets.all(48),
                                  child: Text('暂无消息', textAlign: TextAlign.center, style: TextStyle(color: LL.text2)),
                                ),
                              ])
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                itemCount: _items.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (context, i) => _InboxTile(item: _items[i], onTap: () => _open(_items[i])),
                              ),
                      ),
          ),
        ]),
      ),
    );
  }
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item, required this.onTap});
  final InboxItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (item.category) {
      'territory' => (LL.pink, Icons.flag_rounded),
      'interaction' => (LL.lavender, Icons.favorite_rounded),
      _ => (LL.sky, Icons.campaign_rounded),
    };
    return LLCard(
      padding: const EdgeInsets.all(14),
      onTap: onTap,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: LL.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            if (item.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(item.body, style: const TextStyle(color: LL.text2, height: 1.4)),
            ],
            const SizedBox(height: 6),
            Text(Fmt.relative(item.createdAt), style: const TextStyle(color: LL.text3, fontSize: 12)),
          ]),
        ),
        if (item.territoryId != null)
          const Padding(
            padding: EdgeInsets.only(left: 8, top: 10),
            child: Icon(Icons.chevron_right_rounded, color: LL.text3),
          ),
        if (!item.read)
          Container(
            margin: const EdgeInsets.only(left: 8, top: 16),
            width: 9,
            height: 9,
            decoration: const BoxDecoration(color: LL.red, shape: BoxShape.circle),
          ),
      ]),
    );
  }
}
