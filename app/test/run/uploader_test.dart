import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/api_client.dart';
import 'package:loopland/api/loopland_api.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/auth/token_store.dart';
import 'package:loopland/run/run_store.dart';
import 'package:loopland/run/uploader.dart';

import '../api/api_client_test.dart' show FakeAdapter;
import '../api/fixtures.dart';

void main() {
  test('offline upload stays queued and is retried with the same client_id', () async {
    final dir = await Directory.systemTemp.createTemp('ll_up');
    addTearDown(() => dir.delete(recursive: true));
    final store = RunStore(directory: () async => dir);
    var online = false;
    final seen = <String>[];
    final a = FakeAdapter((o) {
      if (!online) throw DioException.connectionError(requestOptions: o, reason: 'offline');
      seen.add((o.data as Map)['client_id'] as String);
      return (200, j(activityResultJson));
    });
    final up = Uploader(api: LooplandApi(ApiClient(tokens: MemoryTokenStore(access: 'A'), baseUrl: 'http://x', adapter: a)), store: store);
    final upload = ActivityUpload(
      clientId: 'cid-1',
      sport: 'strength',
      startedAt: DateTime.utc(2026, 11, 20),
      endedAt: DateTime.utc(2026, 11, 20, 0, 30),
      durationS: 1800,
      amount: 30,
      device: const DeviceInfo(id: 'd'),
    );

    await expectLater(up.submit(upload), throwsA(anything));
    var pending = await store.pending();
    expect(pending.single.attempts, 1);
    expect(pending.single.lastError, isNotEmpty);

    expect(await up.flush(), isEmpty); // still offline
    online = true;
    final results = await up.flush();
    expect(results.single.settlement.status, 'settled');
    expect(seen, ['cid-1']);
    pending = await store.pending();
    expect(pending, isEmpty);
  });
}
