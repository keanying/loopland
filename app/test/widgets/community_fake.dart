// Method-aware, stateful fake of the community content endpoints
// (docs/api/v2-2-社区.md): feed, posts, comments, profiles, follow / block,
// media, share, reports, replays. Plug into fakeBackend(handlers: [fake.handle]).
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:loopland/claim/geo.dart';

import 'fake_backend.dart' show origin;

typedef J = Map<String, dynamic>;

J brief(int id, String name, {bool crew = false}) => {
      'id': id,
      'nickname': name,
      'avatar_url': null,
      'crew': crew ? {'id': 3, 'name': '城西跑团'} : null,
    };

final kai = brief(7, 'Kai');
final deer = brief(8, '小鹿', crew: true);
final momo = brief(9, 'Momo');
final zhou = brief(10, '老周');
final meBrief = brief(1, '阿杰', crew: true);

/// A wavy run with a couple of crossings (like the prototype thumbnails), as
/// `[lng, lat]` pairs.
List<List<double>> wavyTrack({int n = 120, double scale = 1}) {
  final p = Projection(origin);
  return [
    for (var i = 0; i < n; i++)
      () {
        final t = i / (n - 1) * 2 * math.pi;
        final x = (math.sin(t) * 900 + math.sin(3 * t) * 260) * scale;
        final y = (math.cos(t) * 420 + math.sin(2 * t) * 300) * scale;
        final ll = p.inverse(Point(x, y));
        return [ll.lng, ll.lat];
      }(),
  ];
}

J activityJson(int id, {double km = 10.4, int sec = 3432, double area = 610000}) => {
      'id': id,
      'sport': 'run',
      'distance_m': km * 1000,
      'duration_sec': sec,
      'pace_sec_per_km': sec / km,
      'claimed_area_m2': area,
      'start_time': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
      'track': wavyTrack(),
    };

String ago(Duration d) => DateTime.now().subtract(d).toIso8601String();

J postJson(
  int id,
  J author, {
  String content = '',
  List<J> images = const [],
  J? activity,
  String review = 'approved',
  String? reason,
  int likes = 0,
  int comments = 0,
  int collects = 0,
  int shares = 0,
  String visibility = 'public',
  Duration age = const Duration(hours: 1),
}) =>
    {
      'id': id,
      'author': author,
      'content': content,
      'images': images,
      'activity': activity,
      'visibility': visibility,
      'review_status': review,
      'reject_reason': reason,
      'like_count': likes,
      'comment_count': comments,
      'collect_count': collects,
      'share_count': shares,
      'liked': false,
      'collected': false,
      'created_at': ago(age),
    };

J commentJson(int id, J author, String content,
        {int? parent, J? replyTo, int likes = 0, int replyCount = 0, List<J> replies = const [], String review = 'approved'}) =>
    {
      'id': id,
      'post_id': 101,
      'author': author,
      'content': content,
      'reply_to': replyTo,
      'parent_id': parent,
      'like_count': likes,
      'liked': false,
      'review_status': review,
      'reply_count': replyCount,
      'replies': replies,
      'created_at': ago(const Duration(minutes: 30)),
    };

class CommunityFake {
  CommunityFake() {
    posts = {
      101: postJson(101, kai,
          content: '自由圈地一次连圈 4 块，轨迹交叉的地方全变橙色了。东港这一带今晚归我。 #自由圈地 #夜跑 #城南',
          activity: activityJson(55),
          likes: 128,
          comments: 21,
          collects: 34,
          shares: 12),
      102: postJson(102, deer,
          content: '周六世纪公园晨跑，天气太好了',
          images: [
            for (var i = 1; i <= 3; i++) {'url': 'http://x/img/$i.jpg', 'width': 1080, 'height': 1440}
          ],
          likes: 56,
          comments: 4,
          collects: 2,
          age: const Duration(hours: 3)),
      103: postJson(103, meBrief,
          content: '晨跑打卡，第一次圈到滨江公园',
          activity: activityJson(56, km: 5.2, sec: 1880, area: 180000),
          review: 'pending',
          visibility: 'fans',
          likes: 0,
          age: const Duration(minutes: 20)),
      104: postJson(104, momo, content: '第二页的动态', likes: 3, age: const Duration(days: 1)),
      105: postJson(105, meBrief, content: '加我微信一起跑', review: 'rejected', reason: '含联系方式', age: const Duration(hours: 5)),
    };
    comments = [
      commentJson(9, deer, '东门那块我明早去补一圈，别得意', likes: 24, replyCount: 5, replies: [
        commentJson(21, kai, '来啊，我等着', parent: 9),
        commentJson(22, momo, '带我一个', parent: 9, replyTo: kai),
        commentJson(23, zhou, '+1', parent: 9),
      ]),
      commentJson(10, momo, '轨迹好漂亮', likes: 3),
      commentJson(11, meBrief, '厉害！', likes: 1),
    ];
  }

  late final Map<int, J> posts;
  late final List<J> comments;
  final calls = <RequestOptions>[];
  final following = <int>{9};
  final blocked = <int>{};
  int _media = 200;
  int _nextId = 900;

  /// Overrides POST /v1/posts with an error code (`content_blocked`, `muted`…).
  String? postError;

  int countCalls(String method, String path) =>
      calls.where((o) => o.method == method && o.path == path).length;

  RequestOptions? lastCall(String method, String path) =>
      calls.lastWhere((o) => o.method == method && o.path == path, orElse: () => RequestOptions(path: ''));

  (int, Object?) _err(int status, String code, [String message = '']) => (
        status,
        {
          'error': {'code': code, 'message': message}
        }
      );

  J _profile(int id) {
    final me = id == 1;
    final u = switch (id) { 1 => meBrief, 7 => kai, 8 => deer, 9 => momo, _ => zhou };
    return {
      'user': u,
      'bio': me ? '每天 5 公里' : '自由圈地爱好者，东港一带都是我的',
      'follower_count': me ? 312 : 3214 + (following.contains(id) ? 1 : 0),
      'following_count': me ? following.length + 85 : 210,
      'like_received_count': me ? 4800 : 18600,
      'total_distance_m': me ? 86400 : 1203400,
      'territory_count': me ? 3 : 12,
      'territory_area_m2': me ? 2360000 : 6120000,
      'codex_count': me ? 18 : 23,
      'relation': {
        'following': following.contains(id),
        'followed_by': id == 7,
        'blocked': blocked.contains(id),
        'blocked_by': false,
      },
      'is_self': me,
    };
  }

  (int, Object?)? handle(RequestOptions o) {
    final p = o.path;
    final m = o.method;
    final q = o.queryParameters;
    final body = o.data is Map ? (o.data as Map).cast<String, dynamic>() : <String, dynamic>{};
    RegExpMatch? match(String re) => RegExp('^$re\$').firstMatch(p);
    int idOf(RegExpMatch r) => int.parse(r.group(1)!);

    if (!p.startsWith('/v1/feed') &&
        !p.startsWith('/v1/posts') &&
        !p.startsWith('/v1/comments') &&
        !p.startsWith('/v1/users') &&
        !p.startsWith('/v1/me/') &&
        !p.startsWith('/v1/media') &&
        !p.startsWith('/v1/reports') &&
        !p.startsWith('/v1/replays') &&
        p != '/v1/plans' &&
        !(p == '/v1/activities' && m == 'GET') &&
        !(p.startsWith('/v1/activities/') && p.endsWith('/replay'))) {
      return null;
    }
    calls.add(o);

    if (p == '/v1/feed') {
      if (q['tab'] == 'following') {
        return (200, {'items': [posts[103], posts[105], posts[101]], 'next_cursor': null});
      }
      if (q['cursor'] == 'c2') return (200, {'items': [posts[104]], 'next_cursor': null});
      return (200, {'items': [posts[101], posts[102], posts[103]], 'next_cursor': 'c2'});
    }
    if (p == '/v1/me/collections') return (200, {'items': [posts[102]], 'next_cursor': null});
    if (p == '/v1/me/blocks') {
      return (200, {
        'items': [
          for (final b in blocked) {'user': brief(b, b == 7 ? 'Kai' : '用户$b'), 'blocked_at': ago(const Duration(days: 2))}
        ]
      });
    }
    if (p == '/v1/me' && m == 'PATCH') return null;

    if (p == '/v1/media' && m == 'POST') {
      final id = _media++;
      return (200, {'id': id, 'url': 'http://x/media/$id.jpg', 'width': 1080, 'height': 1440});
    }
    if (p == '/v1/posts' && m == 'POST') {
      if (postError != null) return _err(postError == 'muted' ? 403 : 400, postError!, '内容包含违规信息');
      final id = _nextId++;
      final imgs = (body['image_ids'] as List? ?? const []);
      final post = postJson(id, meBrief,
          content: '${body['content']}',
          images: [for (final i in imgs) {'url': 'http://x/media/$i.jpg', 'width': 1080, 'height': 1440}],
          activity: body['activity_id'] == null ? null : activityJson(body['activity_id'] as int),
          visibility: '${body['visibility']}',
          review: imgs.isEmpty ? 'approved' : 'pending',
          age: Duration.zero);
      posts[id] = post;
      return (200, post);
    }
    if (match(r'/v1/posts/(\d+)') case final r?) {
      final id = idOf(r);
      if (m == 'DELETE') {
        posts.remove(id);
        return (200, <String, dynamic>{});
      }
      final post = posts[id];
      return post == null ? _err(404, 'not_found') : (200, post);
    }
    if (match(r'/v1/posts/(\d+)/like') case final r?) {
      final post = posts[idOf(r)]!;
      final on = m == 'POST';
      if (post['liked'] != on) post['like_count'] = (post['like_count'] as int) + (on ? 1 : -1);
      post['liked'] = on;
      return (200, {'liked': on, 'like_count': post['like_count']});
    }
    if (match(r'/v1/posts/(\d+)/collect') case final r?) {
      final post = posts[idOf(r)]!;
      final on = m == 'POST';
      if (post['collected'] != on) post['collect_count'] = (post['collect_count'] as int) + (on ? 1 : -1);
      post['collected'] = on;
      return (200, {'collected': on, 'collect_count': post['collect_count']});
    }
    if (match(r'/v1/posts/(\d+)/share') case final r?) {
      final post = posts[idOf(r)]!;
      post['share_count'] = (post['share_count'] as int) + 1;
      return (200, {
        'share_count': post['share_count'],
        'url': 'https://loopland.example/p/${post['id']}',
        'poster': {'title': 'Kai 在东港圈了 0.61 km²', 'subtitle': '10.40 km · 5\'29"', 'image_url': null},
      });
    }
    if (match(r'/v1/posts/(\d+)/comments') case final _?) {
      if (m == 'GET') return (200, {'items': comments, 'next_cursor': null});
      final c = commentJson(_nextId++, meBrief, '${body['content']}',
          parent: body['parent_id'] as int?, replyTo: body['reply_to_user_id'] == null ? null : kai);
      if (body['parent_id'] == null) comments.add(c);
      return (200, c);
    }
    if (match(r'/v1/comments/(\d+)/replies') case final _?) {
      return (200, {
        'items': [
          ...(comments.first['replies'] as List),
          commentJson(24, deer, '那就明早 6 点东门见', parent: 9, replyTo: momo),
          commentJson(25, kai, '一言为定', parent: 9, replyTo: deer),
        ],
        'next_cursor': null,
      });
    }
    if (match(r'/v1/comments/(\d+)/like') case final r?) {
      final on = m == 'POST';
      final id = idOf(r);
      final c = comments.firstWhere((e) => e['id'] == id, orElse: () => {'like_count': 0});
      c['like_count'] = (c['like_count'] as int) + (on ? 1 : -1);
      return (200, {'liked': on, 'like_count': c['like_count']});
    }
    if (match(r'/v1/comments/(\d+)') case final r? when m == 'DELETE') {
      comments.removeWhere((e) => e['id'] == idOf(r));
      return (200, <String, dynamic>{});
    }
    if (p == '/v1/reports' && m == 'POST') return (200, {'id': 5});

    if (match(r'/v1/users/(\d+)') case final r?) return (200, _profile(idOf(r)));
    if (match(r'/v1/users/(\d+)/posts') case final r?) {
      final id = idOf(r);
      if (blocked.contains(id)) return (200, {'items': [], 'next_cursor': null});
      return (200, {
        'items': [for (final post in posts.values) if ((post['author'] as Map)['id'] == id) post],
        'next_cursor': null,
      });
    }
    if (match(r'/v1/users/(\d+)/follow') case final r?) {
      final id = idOf(r);
      if (blocked.contains(id)) return _err(403, 'blocked');
      m == 'POST' ? following.add(id) : following.remove(id);
      return (200, {'following': m == 'POST'});
    }
    if (match(r'/v1/users/(\d+)/block') case final r?) {
      final id = idOf(r);
      if (m == 'POST') {
        blocked.add(id);
        following.remove(id);
      } else {
        blocked.remove(id);
      }
      return (200, <String, dynamic>{});
    }
    if (match(r'/v1/users/(\d+)/(followers|following)') case final r?) {
      return (200, {
        'items': [
          {'user': kai, 'following': following.contains(7), 'followed_at': ago(const Duration(days: 3))},
          {'user': deer, 'following': following.contains(8), 'followed_at': ago(const Duration(days: 9))},
          if (r.group(2) == 'following') {'user': momo, 'following': true, 'followed_at': ago(const Duration(days: 20))},
        ],
        'next_cursor': null,
      });
    }

    if (p == '/v1/replays' || p.endsWith('/replay')) {
      J replay(int postId, J author, double scale, int sec) {
        final pts = wavyTrack(n: 160, scale: scale);
        return {
          'post_id': postId,
          'author': author,
          'activity': {'id': postId - 46, 'sport': 'run', 'distance_m': 10400 * scale, 'duration_sec': sec, 'claimed_area_m2': 610000},
          'points': [
            for (var i = 0; i < pts.length; i++) {'lng': pts[i][0], 'lat': pts[i][1], 't': sec * i / (pts.length - 1)}
          ],
          'like_count': 1300,
          'liked': false,
        };
      }

      if (p != '/v1/replays') return (200, replay(101, kai, 1, 3432));
      return (200, {
        'items': [replay(101, kai, 1, 3432), replay(102, deer, 0.6, 1880)],
        'next_cursor': null
      });
    }

    if (p == '/v1/plans') {
      return (200, {
        'items': [
          {
            'code': 'auto_month',
            'name': '连续包月',
            'period': 'month',
            'price_fen': 1800,
            'entitlements': ['map_styles', 'hd_replay_export'],
          }
        ],
        'minor_blocked': false,
      });
    }
    if (p == '/v1/activities') {
      return (200, {
        'items': [
          {
            'id': 56,
            'sport': 'run',
            'status': 'settled',
            'started_at': ago(const Duration(hours: 3)),
            'distance_m': 5200,
            'duration_s': 1880,
            'avg_pace_s_per_km': 361,
            'claimed_area_m2': 180000,
          },
          {
            'id': 57,
            'sport': 'run',
            'status': 'settled',
            'started_at': ago(const Duration(days: 1, hours: 2)),
            'distance_m': 8200,
            'duration_s': 2825,
            'avg_pace_s_per_km': 344,
            'claimed_area_m2': 0,
          },
        ],
        'total': 2,
      });
    }
    return _err(404, 'not_found');
  }
}
