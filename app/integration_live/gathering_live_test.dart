// Gatherings & messages API layer (lib/api/gathering_api.dart) against a live
// dev backend: crew invite / edit, rally + check-in + settlement bonus,
// meetups, direct / group chat with realtime, races + settlement medal,
// inbox summary, community home.
//
//   LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live/gathering_live_test.dart
//
// The backend must run with LOOPLAND_ENV=dev (SMS code 000000) and the
// bootstrap admin admin:admin-password-1 (to publish a race).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/community_api.dart';
import 'package:loopland/api/errors.dart';
import 'package:loopland/api/gathering_api.dart';
import 'package:loopland/api/gathering_models.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/claim/geo.dart';
import 'package:loopland/realtime/realtime_client.dart';
import 'package:uuid/uuid.dart';

const origin = LatLng(31.2304, 121.4737);

/// 1×1 PNG.
final pngBytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// A square loop of [side] metres around [dx], [dy] that ends now.
ActivityUpload runEndingNow(double dx, double dy, {double side = 300, double speed = 3}) {
  final proj = Projection(origin);
  final wps = [
    [0.0, 0.0], [side, 0.0], [side, side], [side / 2, side], [side / 2, -50.0]
  ];
  final rel = <(double, double)>[];
  var t = 0.0;
  rel.add((wps[0][0], wps[0][1]));
  final times = <double>[0];
  for (var i = 1; i < wps.length; i++) {
    final a = wps[i - 1], b = wps[i];
    final d = math.sqrt(math.pow(b[0] - a[0], 2) + math.pow(b[1] - a[1], 2));
    final n = (d / 5).ceil();
    for (var k = 1; k <= n; k++) {
      t += d / n / speed;
      rel.add((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n));
      times.add(t);
    }
  }
  final end = DateTime.now().subtract(const Duration(seconds: 5));
  final start = end.subtract(Duration(milliseconds: (t * 1000).round()));
  final pts = [
    for (var i = 0; i < rel.length; i++)
      () {
        final ll = proj.inverse(Point(dx + rel[i].$1, dy + rel[i].$2));
        return TrackPoint(t: start.millisecondsSinceEpoch + (times[i] * 1000).round(), lat: ll.lat, lng: ll.lng, acc: 5);
      }(),
  ];
  return ActivityUpload(
    clientId: const Uuid().v4(),
    sport: 'run',
    startedAt: start,
    endedAt: end,
    durationS: t.round(),
    points: pts,
    device: const DeviceInfo(id: 'live-gathering', model: 'live-test', os: 'test'),
  );
}

class Session {
  Session(this.c) : api = LooplandApi(c), g = GatheringApi(c), community = CommunityApi(c);
  final ApiClient c;
  final LooplandApi api;
  final GatheringApi g;
  final CommunityApi community;
  late User me;
}

void main() {
  final base = Platform.environment['LOOPLAND_LIVE_API'];
  final skip = base == null ? 'set LOOPLAND_LIVE_API to run' : false;
  final rnd = math.Random().nextInt(90000000) + 10000000;

  Future<Session> login(String phone) async {
    final s = Session(ApiClient(tokens: MemoryTokenStore(), baseUrl: base, platform: 'android'));
    await s.api.sendSms(phone);
    await s.api.login('sms', {'phone': phone, 'code': '000000'});
    s.me = await s.api.setConsents(privacyVersion: '2026-11', location: true, health: true);
    return s;
  }

  test('crew invite / edit, rally check-in + bonus, meetups, chat + realtime, races, inbox, home', () async {
    final a = await login('137$rnd');
    final b = await login('136$rnd');
    final dx = rnd % 50 * 1000.0 + 60000; // a quiet corner of the map per run

    // ── 社区首页 without a crew ──
    var home = await a.g.communityHome();
    expect(home.crew, isNull);

    // ── 跑团：创建、邀请码、编辑 ──
    final crew = await a.api.createCrew(name: '测试团$rnd'.substring(0, 11), district: '徐汇区', joinMode: 'invite');
    final invite = await a.g.createInvite(crew.id);
    expect(invite.code, isNotEmpty);
    expect(invite.expiresAt!.isAfter(DateTime.now().add(const Duration(days: 6))), isTrue);
    await expectLater(b.g.joinByCode('ZZZZZZ'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'invalid_invite')));
    expect(await b.g.joinByCode(invite.code.toLowerCase()), crew.id);
    final avatar = await a.community.uploadMedia(pngBytes, filename: 'crew.png', purpose: 'crew_avatar');
    final edited = await a.g.updateCrew(crew.id, name: '新名$rnd'.substring(0, 10), avatarId: avatar.id, joinMode: 'apply');
    expect(edited.name, '新名$rnd'.substring(0, 10));
    expect(edited.joinMode, 'apply');
    expect(edited.avatarUrl, isNotNull);
    home = await a.g.communityHome();
    expect(home.crew?.id, crew.id);
    expect(home.crew?.memberCount, 2);

    // ── 集结跑 ──
    final meet = Projection(origin).inverse(Point(dx, 0));
    final rallyPlace = Place(name: '集合点', lat: meet.lat, lng: meet.lng);
    final rallyStart = DateTime.now().add(const Duration(seconds: 70));
    final rally = await a.g.createRally(crew.id, title: '夜跑', startTime: rallyStart, place: rallyPlace, distanceGoalM: 5000);
    expect(rally.joined, isTrue);
    expect(rally.conversationId, isNotNull);
    expect((await b.g.rallies(crew.id)).map((r) => r.id), contains(rally.id));
    var br = await b.g.joinRally(rally.id);
    expect(br.joined, isTrue);
    final far = Projection(origin).inverse(Point(dx + 2000, 0));
    await expectLater(b.g.checkinRally(rally.id, far),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'checkin_not_allowed').having((e) => e.message, 'message', isNotEmpty)));
    br = await b.g.checkinRally(rally.id, meet);
    expect(br.checkedIn, isTrue);
    expect(br.bonusActive, isFalse);
    final ar = await a.g.checkinRally(rally.id, meet);
    expect(ar.checkedInCount, 2);
    expect(ar.bonusActive, isTrue);
    home = await b.g.communityHome();
    expect(home.rallies.map((r) => r.id), contains(rally.id));

    // ── 组局 ──
    final mStart = DateTime.now().add(const Duration(hours: 3));
    final m = await a.g.createMeetup(MeetupDraft(
      type: 'run',
      title: '周末约跑',
      description: '配速六分',
      startTime: mStart,
      endTime: mStart.add(const Duration(hours: 2)),
      place: rallyPlace,
      capacity: 5,
      requirement: '配速 6 分',
    ));
    expect(m.joined, isTrue);
    expect(m.conversationId, isNotNull);
    expect(['approved', 'pending'], contains(m.reviewStatus));
    if (m.reviewStatus == 'approved') {
      final near = await b.g.meetups(type: 'run', near: meet);
      final found = near.items.firstWhere((x) => x.id == m.id);
      expect(found.distanceM, isNotNull);
      expect(found.distanceM!, lessThan(50));
      final joined = await b.g.joinMeetup(m.id);
      expect(joined.joined, isTrue);
      expect(joined.joinedCount, 2);
      final detail = await b.g.meetup(m.id);
      expect(detail.members.map((u) => u.id), containsAll([a.me.id, b.me.id]));
      expect((await b.g.myMeetups()).map((x) => x.id), contains(m.id));
      expect((await b.g.leaveMeetup(m.id)).joined, isFalse);
    }

    // ── 私信 / 群聊 + 实时 ──
    final events = <ChatEvent>[];
    final ws = RealtimeClient(baseUrl: base!, token: () => a.c.tokens.accessToken);
    final sub = ws.events.listen((e) {
      final ce = e is UnknownEvent ? ChatEvent.parse(e.raw) : null;
      if (ce != null) events.add(ce);
    });
    ws.start();
    await ws.statusChanges.firstWhere((s) => s == RealtimeStatus.connected).timeout(const Duration(seconds: 10));

    final conv = await b.g.openDirect(a.me.id);
    expect(conv.type, 'direct');
    expect(conv.peer?.id, a.me.id);
    expect((await b.g.openDirect(a.me.id)).id, conv.id);
    final m1 = await b.g.sendText(conv.id, '你好，周末一起跑？');
    expect(m1.type, 'text');
    await b.g.sendText(conv.id, '第二条');
    final up = await b.community.uploadMedia(pngBytes, filename: 'chat.png', purpose: 'chat');
    final img = await b.g.sendImage(conv.id, up.id);
    expect(img.type, 'image');
    expect(img.imageUrl, isNotNull);
    // A doesn't follow B and hasn't replied: the 4th message is refused.
    await expectLater(b.g.sendText(conv.id, '第四条'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'stranger_limit')));

    // A sees it pushed and in the list, with unread.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(events.whereType<ChatMessageEvent>().map((e) => e.message.id), contains(m1.id));
    final aConvs = await a.g.conversations();
    final ac = aConvs.items.firstWhere((x) => x.id == conv.id);
    expect(ac.unreadCount, 3);
    expect(ac.lastMessage?.id, img.id);
    final summary = await a.g.inboxSummary();
    expect(summary.chat, greaterThanOrEqualTo(3));
    final page1 = await a.g.messages(conv.id, limit: 2);
    expect(page1.items.first.id, img.id);
    expect(page1.hasMore, isTrue);
    final page2 = await a.g.messages(conv.id, before: page1.nextCursor, limit: 2);
    expect(page2.items.map((x) => x.id), contains(m1.id));
    await a.g.markConversationRead(conv.id, img.id);
    expect((await a.g.conversations()).items.firstWhere((x) => x.id == conv.id).unreadCount, 0);
    // A replies; B is no longer limited. The read receipt reaches B's socket.
    await a.g.sendText(conv.id, '好呀');
    await b.g.sendText(conv.id, '第四条');
    await a.g.muteConversation(conv.id, true);
    expect((await a.g.conversations()).items.firstWhere((x) => x.id == conv.id).muted, isTrue);

    // Group chat of the rally: B's message reaches A over the socket.
    final rallyConv = rally.conversationId!;
    final gm = await b.g.sendText(rallyConv, '我到了');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(events.whereType<ChatMessageEvent>().map((e) => e.message.id), contains(gm.id));
    final groups = await a.g.conversations();
    final group = groups.items.firstWhere((x) => x.id == rallyConv);
    expect(group.isGroup, isTrue);
    expect(group.refType, 'rally');
    expect(await a.g.findConversation(rallyConv), isNotNull);

    // Delete (hide) the direct conversation.
    await a.g.deleteConversation(conv.id);
    expect((await a.g.conversations()).items.map((x) => x.id), isNot(contains(conv.id)));
    await sub.cancel();
    await ws.dispose();

    // ── 赛事：管理端发布一场正在进行的线上赛 ──
    final admin = Dio(BaseOptions(baseUrl: base, contentType: 'application/json'));
    final al = await admin.post<Map<String, dynamic>>('/admin/v1/login', data: {'username': 'admin', 'password': 'admin-password-1'});
    admin.options.headers['Authorization'] = 'Bearer ${al.data!['token']}';
    final now = DateTime.now().toUtc();
    final created = await admin.post<Map<String, dynamic>>('/admin/v1/races', data: {
      'type': 'online',
      'title': '直播 1K $rnd',
      'description': '联调',
      'sport': 'run',
      'distance_m': 1000,
      'start_time': now.subtract(const Duration(hours: 2)).toIso8601String(),
      'end_time': now.add(const Duration(days: 1)).toIso8601String(),
      'signup_end_time': now.add(const Duration(hours: 12)).toIso8601String(),
      'capacity': 100,
      'requires_wearable': false,
      'medal': {'key': 'race_live_$rnd', 'name': '联调奖牌'},
      'published': true,
    });
    final raceId = created.data!['id'] as int;
    final race = await a.g.race(raceId);
    expect(race.title, '直播 1K $rnd');
    expect(race.myEntry, isNull);
    final listed = await a.g.races();
    expect(listed.items.map((r) => r.id), contains(raceId));
    var signed = await a.g.signupRace(raceId);
    expect(signed.myEntry?.status, 'signed');
    // Already started: cancelling is refused (409 race_started).
    await expectLater(a.g.cancelRaceSignup(raceId), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'race_started')));
    // The server reports `running` once the window opened, signup still open.
    expect(signed.status, 'running');
    expect(signed.canSignupAt(DateTime.now()), isFalse); // already signed

    // ── 结算：集结加成 + 赛事完赛 ──
    final wait = rallyStart.difference(DateTime.now()) + const Duration(seconds: 10); // the run ends 5 s before the upload
    if (!wait.isNegative) await Future<void>.delayed(wait);
    final res = await a.api.uploadActivity(runEndingNow(dx, 100));
    expect(res.settlement.status, 'settled');
    expect(res.settlement.rally?.rallyId, rally.id);
    expect(res.settlement.rally?.bonusRate, greaterThan(0));
    expect(res.settlement.races.map((r) => r.raceId), contains(raceId));
    final fin = res.settlement.races.firstWhere((r) => r.raceId == raceId);
    expect(fin.medalName, '联调奖牌');
    expect(fin.resultSec, greaterThan(0));
    final after = await a.g.race(raceId);
    expect(after.myEntry?.finished, isTrue);
    expect(after.leaderboard.map((e) => e.user.id), contains(a.me.id));

    // ── 消息分类 ──
    final s = await a.g.inboxSummary();
    expect(s.total, greaterThanOrEqualTo(0));
    final inbox = await a.g.inbox(category: 'system');
    expect(inbox.items.every((i) => i.category == 'system'), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 4)));
}
