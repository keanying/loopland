import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/api/models.dart';
import 'package:loopland/core/providers.dart';
import 'package:loopland/features/codex/codex_page.dart';
import 'package:loopland/widgets/card_art.dart';
import 'package:material_ui/material_ui.dart';

import '../api/fixtures.dart';
import 'fake_backend.dart';
import 'test_helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('codex grid: obtained vs silhouette cards, tabs, detail sheet', (t) async {
    await phone(t);
    final codex = Codex.fromJson(j(codexJson));
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: wrap(const CodexPage(), overrides: [
        ...fakeBackend(),
        codexProvider.overrideWith((ref) async => codex),
      ]),
    ));
    await t.pump();
    await t.pump();

    // Header & progress: 3 obtained of 7.
    expect(find.text('图鉴'), findsOneWidget);
    expect(find.text('2/8'), findsOneWidget); // server progress string for 角色
    // Roles tab: knight obtained, archer still a silhouette with progress.
    expect(find.text('骑士'), findsOneWidget);
    expect(find.text('???'), findsOneWidget);
    expect(find.text('跑步 12.4 / 30.0 km'), findsOneWidget);
    final cards = t.widgetList<CardArt>(find.byType(CardArt)).toList();
    expect(cards.where((c) => c.locked), hasLength(1));
    expect(cards.where((c) => !c.locked), hasLength(1));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/codex.png');

    // Detail sheet for the locked archer shows how to unlock.
    await t.tap(find.text('???'));
    await t.pumpAndSettle();
    expect(find.textContaining('跑步累计 30.0 km招募'), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();

    // Companions: egg banner + escort.
    await t.tap(find.text('伙伴'));
    await t.pump();
    expect(find.text('神秘蛋 · 孵化中'), findsOneWidget);
    expect(find.text('陪跑中 · Lv.1'), findsOneWidget);

    // No monsters in a V1 payload: the intro card is shown.
    await t.tap(find.text('怪兽'));
    await t.pump();
    expect(find.text('城市怪兽'), findsOneWidget);
    await settle(t);
  });
}
