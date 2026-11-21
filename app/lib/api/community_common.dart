// Shared pieces for V2 batch 2「社区」(docs/api/v2-2-社区.md): the UserBrief
// object, cursor pagination and tolerant JSON helpers. Used by both the
// content side (feed / posts / profiles / replay) and the messaging side
// (chat / meetups / rallies / races). The list widget is
// lib/widgets/cursor_list.dart.
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';

// ── tolerant JSON helpers (public so feature models in other files can reuse) ──

double jd(Object? v, [double def = 0]) => v is num ? v.toDouble() : def;
double? jdn(Object? v) => v is num ? v.toDouble() : null;
int ji(Object? v, [int def = 0]) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? def : def);
int? jin(Object? v) => v is num ? v.toInt() : null;
String js(Object? v, [String def = '']) => v is String ? v : (v?.toString() ?? def);
String? jsn(Object? v) => v is String && v.isNotEmpty ? v : null;
bool jb(Object? v, [bool def = false]) => v is bool ? v : def;
DateTime? jdt(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
Json jm(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
Json? jmn(Object? v) => v is Map ? v.cast<String, dynamic>() : null;
List<T> jl<T>(Object? v, T Function(Json) f) =>
    v is List ? [for (final e in v) if (e is Map) f(e.cast<String, dynamic>())] : <T>[];

/// `UserBrief`: every place a user appears in the community APIs.
/// `crew` is null without a crew; deleted users read「已注销用户」.
class UserBrief {
  const UserBrief({required this.id, required this.nickname, this.avatarUrl, this.crew, this.avatarFrame});
  final int id;
  final String nickname;
  final String? avatarUrl;
  final CrewRef? crew;

  /// V2 batch 4 (E-05): key of the equipped avatar frame (`frame_gold`, …),
  /// drawn by UserAvatar; null = none.
  final String? avatarFrame;

  bool get isDeleted => nickname == '已注销用户';

  factory UserBrief.fromJson(Json j) => UserBrief(
        id: ji(j['id']),
        nickname: js(j['nickname']),
        avatarUrl: jsn(j['avatar_url']),
        crew: jmn(j['crew']) == null ? null : CrewRef.fromJson(jm(j['crew'])),
        avatarFrame: jsn(j['avatar_frame']),
      );

  static UserBrief? maybe(Object? v) => v is Map ? UserBrief.fromJson(v.cast<String, dynamic>()) : null;

  Json toJson() => {
        'id': id,
        'nickname': nickname,
        'avatar_url': avatarUrl,
        'crew': crew == null ? null : {'id': crew!.id, 'name': crew!.name},
        'avatar_frame': avatarFrame,
      };
}

/// One page of a cursor list: `{"items":[...],"next_cursor":"..."|null}`.
class CursorPage<T> {
  const CursorPage(this.items, this.nextCursor);
  final List<T> items;

  /// Opaque; send back unchanged. null = no more pages.
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory CursorPage.fromJson(Object? raw, T Function(Json) f) {
    final j = jm(raw);
    final c = j['next_cursor'];
    return CursorPage(jl(j['items'], f), c == null ? null : '$c');
  }
}

/// Query map for a cursor request (`?cursor=&limit=`, limit ≤ 50).
Map<String, dynamic> cursorQuery(String? cursor, {int? limit, Map<String, dynamic> extra = const {}}) => {
      ...extra,
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      if (limit != null) 'limit': limit.clamp(1, 50),
    };

/// GET [path] as a cursor page.
Future<CursorPage<T>> getCursorPage<T>(
  ApiClient c,
  String path,
  T Function(Json) parse, {
  String? cursor,
  int? limit,
  Map<String, dynamic> query = const {},
}) async =>
    CursorPage.fromJson(await c.get(path, query: cursorQuery(cursor, limit: limit, extra: query)), parse);

/// Accumulates cursor pages for an infinite list. Single-flight: calling
/// [loadMore] while a page is loading is a no-op; [refresh] restarts from the
/// first page and drops any in-flight result.
///
/// ```dart
/// final pager = CursorPager<Post>((cursor) => api.feed('recommend', cursor: cursor));
/// pager.refresh();
/// ```
class CursorPager<T> extends ChangeNotifier {
  CursorPager(this.fetch);

  final Future<CursorPage<T>> Function(String? cursor) fetch;

  List<T> _items = <T>[];
  String? _cursor;
  bool _started = false;
  bool _done = false;
  bool _loading = false;
  Object? _error;
  int _gen = 0;
  bool _disposed = false;

  List<T> get items => _items;
  bool get loading => _loading;
  bool get hasMore => !_done;
  Object? get error => _error;

  /// True before the first page arrived (show a spinner, not "empty").
  bool get initialLoading => !_started || (_loading && _items.isEmpty && _error == null);
  bool get isEmpty => _started && _done && _items.isEmpty;

  Future<void> refresh() {
    _gen++;
    _cursor = null;
    _done = false;
    _loading = false;
    _error = null;
    return _load(reset: true);
  }

  Future<void> loadMore() => (_loading || _done) ? Future.value() : _load();

  Future<void> _load({bool reset = false}) async {
    final gen = _gen;
    _loading = true;
    _started = true;
    _notify();
    try {
      final p = await fetch(reset ? null : _cursor);
      if (gen != _gen || _disposed) return;
      _items = reset ? List.of(p.items) : [..._items, ...p.items];
      _cursor = p.nextCursor;
      _done = !p.hasMore;
      _error = null;
    } catch (e) {
      if (gen != _gen || _disposed) return;
      _error = e;
      if (reset) _items = <T>[];
    } finally {
      if (gen == _gen && !_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Local edits (optimistic delete, prepend a new post, …).
  void removeWhere(bool Function(T) test) {
    _items = _items.where((e) => !test(e)).toList();
    _notify();
  }

  void replaceWhere(bool Function(T) test, T Function(T) update) {
    _items = [for (final e in _items) test(e) ? update(e) : e];
    _notify();
  }

  void insertFirst(T item) {
    _items = [item, ..._items];
    _notify();
  }

  void append(T item) {
    _items = [..._items, item];
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
