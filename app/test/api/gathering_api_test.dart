import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/gathering_api.dart';
import 'package:loopland/api/gathering_models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';

import 'api_client_test.dart' show FakeAdapter;

void main() {
  (GatheringApi, FakeAdapter) api(Object? Function(String path) body) {
    final a = FakeAdapter((o) => (200, body(o.path)));
    return (GatheringApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: a)), a);
  }

  test('messages paging sends before + limit; next_cursor is the older id', () async {
    final (g, a) = api((_) => {
          'items': [
            {'id': 77, 'conversation_id': 4, 'sender': null, 'type': 'system', 'content': '小鹿 加入了群聊', 'payload': {}},
            {
              'id': 76, 'conversation_id': 4, 'sender': {'id': 7, 'nickname': 'Kai', 'avatar_url': null, 'crew': null},
              'type': 'image', 'content': '', 'payload': {'url': 'https://x/1.jpg', 'width': 800, 'height': 600},
            },
          ],
          'next_cursor': '76',
        });
    final p = await g.messages(4, before: '80');
    expect(a.requests.single.queryParameters, {'before': '80', 'limit': 30});
    expect(p.nextCursor, '76');
    expect(p.items.first.isSystem, isTrue);
    expect(p.items.last.imageUrl, 'https://x/1.jpg');
    expect(p.items.last.preview, '[图片]');
  });

  test('meetups near: lat / lng / radius and type; draft validation', () async {
    final (g, a) = api((_) => {'items': [], 'next_cursor': null});
    await g.meetups(type: 'ball', near: const LatLng(31.2, 121.4));
    expect(a.requests.single.queryParameters, {'type': 'ball', 'lat': '31.200000', 'lng': '121.400000', 'radius_m': 10000});

    final now = DateTime(2026, 11, 21, 10);
    MeetupDraft d({DateTime? start, Duration len = const Duration(hours: 2), int cap = 10, String title = '约跑'}) => MeetupDraft(
          type: 'run',
          title: title,
          startTime: start ?? now.add(const Duration(hours: 2)),
          endTime: (start ?? now.add(const Duration(hours: 2))).add(len),
          place: const Place(name: '东门', lat: 31.2, lng: 121.4),
          capacity: cap,
        );
    expect(d().validate(now: now), isNull);
    expect(d(start: now.add(const Duration(minutes: 30))).validate(now: now), contains('1 小时'));
    expect(d(start: now.add(const Duration(days: 31))).validate(now: now), contains('30 天'));
    expect(d(len: const Duration(hours: 13)).validate(now: now), contains('12 小时'));
    expect(d(cap: 1).validate(now: now), contains('2–50'));
    expect(d(title: 'x' * 31).validate(now: now), contains('30'));
  });

  test('rally check-in body, invite code upper-cased, crew patch omits nulls', () async {
    final (g, a) = api((p) => p.endsWith('join-by-code') ? {'status': 'joined', 'crew_id': 3} : {'id': 5});
    await g.checkinRally(5, const LatLng(31.19, 121.43));
    expect(a.requests.last.data, {'lat': 31.19, 'lng': 121.43});
    expect(await g.joinByCode(' 8k2d9q '), 3);
    expect(a.requests.last.data, {'code': '8K2D9Q'});
    await g.updateCrew(3, avatarId: 12);
    expect(a.requests.last.method, 'PATCH');
    expect(a.requests.last.data, {'avatar_id': 12});
  });

  test('home, summary, race and chat events parse', () {
    final h = CommunityHome.fromJson({
      'crew': null,
      'unread': {'interaction': 3, 'chat': 5},
      'rallies': [
        {'id': 5, 'title': '周三夜跑', 'bonus_active': true, 'place': {'name': '徐家汇公园', 'lat': 31.19, 'lng': 121.43}},
      ],
      'meetups': [],
      'races': [
        {'id': 2, 'status': 'signup', 'capacity': 10, 'signed_count': 10, 'my_entry': null},
      ],
    });
    expect(h.crew, isNull);
    expect(h.unreadChat, 5);
    expect(h.rallies.single.bonusActive, isTrue);
    expect(h.races.single.canSignup, isFalse); // full
    expect(InboxSummary.fromJson({'interaction': 1, 'monster': 2, 'chat': 4}).total, 7);
    final e = ChatEvent.parse({'type': 'conversation_read', 'conversation_id': 4, 'user_id': 7, 'message_id': 77});
    expect(e, isA<ConversationReadEvent>().having((x) => x.messageId, 'messageId', 77));
    expect(ChatEvent.parse({'type': 'ping'}), isNull);
  });
}
