import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/features/run/result_page.dart';
import 'package:loopland/map/territory_map.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'fake_backend.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(() async {
    TerritoryMapView.forceFallback = true;
    await loadFonts();
  });

  testWidgets('result page: claims, attacks, energy, recruits, eggs, medals', (t) async {
    await phone(t, size: const Size(390, 1900));
    final r = ActivityResult.fromJson(j(activityResultJson));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(ResultPage(args: ResultArgs(result: r)), overrides: fakeBackend()),
    ));
    await idle(t);

    expect(find.text('圈地成功！'), findsOneWidget);
    expect(find.text('+53'), findsOneWidget);
    expect(find.text('新圈 领地 #101'), findsOneWidget);
    expect(find.textContaining('守卫 120 → 67'), findsOneWidget);
    expect(find.text('弓箭手'), findsOneWidget);
    expect(find.text('12.4 / 30.0 km'), findsOneWidget);
    expect(find.textContaining('还差 6.4 km 孵化'), findsOneWidget);
    expect(find.text('百公里'), findsWidgets);
    expect(find.textContaining('今日能量已达上限'), findsNothing);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/result.png');
    await settle(t);
  });

  testWidgets('result page: capped energy and review / voided states', (t) async {
    await phone(t, size: const Size(390, 1400));
    final m = j(activityResultJson);
    (m['settlement'] as Map)
      ..['energy_capped'] = true
      ..['energy_raw'] = 80
      ..['energy_granted'] = 20;
    await t.pumpWidget(wrap(ResultPage(args: ResultArgs(result: ActivityResult.fromJson(m))), overrides: fakeBackend()));
    await t.pump();
    expect(find.textContaining('今日能量已达上限 600，本次应得 80'), findsOneWidget);

    (m['settlement'] as Map)['status'] = 'review';
    await t.pumpWidget(wrap(ResultPage(args: ResultArgs(result: ActivityResult.fromJson(m))), overrides: fakeBackend()));
    await t.pump();
    expect(find.text('本次记录进入人工复核'), findsOneWidget);
    expect(find.textContaining('平均速度 24.3 km/h'), findsOneWidget);
    expect(find.text('+20'), findsNothing); // no energy shown while in review

    (m['settlement'] as Map)['status'] = 'voided';
    await t.pumpWidget(wrap(ResultPage(args: ResultArgs(result: ActivityResult.fromJson(m))), overrides: fakeBackend()));
    await t.pump();
    expect(find.text('本次记录已作废'), findsOneWidget);
    await settle(t);
  });
}
