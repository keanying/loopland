import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/features/ai/ai_widgets.dart';
import 'package:loopland/widgets/l_icons.dart';

import 'test_helpers.dart';

/// 图标总览：全部 [LIcons] 在深色和浅色底上各一份，外加「圈圈」标志的各个尺寸。
/// `LOOPLAND_SCREENSHOTS=1 flutter test` 时写到 screenshots/icons_sheet.png。
void main() {
  setUpAll(loadFonts);

  testWidgets('LIcon takes size and color from IconTheme like Icon', (t) async {
    await t.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: IconTheme(
        data: IconThemeData(size: 31, color: Color(0xFF123456)),
        child: Center(child: LIcon(LIcons.flag, semanticLabel: '旗')),
      ),
    ));
    expect(t.getSize(find.byType(LIcon)), const Size(31, 31));
    expect(find.bySemanticsLabel('旗'), findsOneWidget);
    // 线宽：24 px 时 1.8，小尺寸加粗
    expect(LGlyph.strokeUnits(24), 1.8);
    expect(LGlyph.strokeUnits(12), greaterThan(2));
  });

  testWidgets('every glyph parses and paints', (t) async {
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Wrap(children: [
        for (final g in LIcons.all) ...[LIcon(g, size: 24, color: LL.text), LIcon(g, size: 12, color: const Color(0x88FFFFFF))],
        const QuanMark(size: 44),
      ]),
    ));
    expect(t.takeException(), isNull);
    expect(LIcons.all.map((g) => g.name).toSet().length, LIcons.all.length);
  });

  testWidgets('icon contact sheet', (t) async {
    await phone(t, size: const Size(1280, 2400));
    await t.pumpWidget(wrap(const Align(alignment: Alignment.topCenter, child: RepaintBoundary(key: ValueKey('sheet'), child: _Sheet()))));
    await t.pump();
    await screenshot(t, find.byKey(const ValueKey('sheet')), 'screenshots/icons_sheet.png');
  });
}

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) {
    final proto = LIcons.all.where((g) => g.proto).length;
    return Material(
      color: LL.night,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Text(
            '圈圈 Loopland 图标 · ${LIcons.all.length} 个（绿点 = 取自原型 $proto 个，其余 ${LIcons.all.length - proto} 个按原型画法新画）'
            ' · 每格：28 / 20 / 14 px',
            style: const TextStyle(color: LL.text, fontWeight: FontWeight.w800, fontSize: 16),
          ),
        ),
        const _Panel(bg: LL.night, fg: LL.text, sub: LL.text3),
        const _Panel(bg: Color(0xFFF4F4F5), fg: LL.ink, sub: Color(0xFF6A6A72)),
        Container(
          color: LL.card,
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            const Text('圈圈（AI 助手）', style: TextStyle(color: LL.text, fontWeight: FontWeight.w800)),
            const SizedBox(width: 20),
            for (final s in [12.0, 16.0, 20.0, 24.0, 32.0, 44.0]) ...[QuanMark(size: s), const SizedBox(width: 16)],
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LL.lavender, borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                QuanMark(size: 22, ringColor: LL.ink),
                SizedBox(width: 8),
                QuanMark(size: 32, ringColor: LL.ink),
              ]),
            ),
            const SizedBox(width: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LL.lime, borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                LIcon(LIcons.quan, size: 18, color: LL.ink),
                SizedBox(width: 8),
                LIcon(LIcons.quan, size: 28, color: LL.ink),
              ]),
            ),
            const SizedBox(width: 16),
            // 地图右侧「圈圈」入口：圈圈 + AI 角标
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              decoration: const ShapeDecoration(color: LL.lavender, shape: StadiumBorder()),
              child: const Row(children: [
                AIMark(),
                SizedBox(width: 14),
                Text('圈圈', style: TextStyle(color: LL.ink, fontWeight: FontWeight.w900, fontSize: 17)),
              ]),
            ),
            const SizedBox(width: 16),
            const AIBadge(),
            const SizedBox(width: 16),
            const AILabel(),
            const SizedBox(width: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFF4F4F5), borderRadius: BorderRadius.circular(12)),
              child: const Row(children: [
                QuanMark(size: 24, ringColor: LL.ink),
                SizedBox(width: 8),
                QuanMark(size: 44, ringColor: LL.ink),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.bg, required this.fg, required this.sub});
  final Color bg, fg, sub;

  @override
  Widget build(BuildContext context) => Container(
        color: bg,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Wrap(spacing: 4, runSpacing: 6, children: [
          for (final g in LIcons.all)
            SizedBox(
              width: 108,
              height: 66,
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  LIcon(g, size: 28, color: fg),
                  const SizedBox(width: 8),
                  LIcon(g, size: 20, color: fg),
                  const SizedBox(width: 6),
                  LIcon(g, size: 14, color: fg),
                ]),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (g.proto) ...[
                    Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF8DBA1E), shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(child: Text(g.name, overflow: TextOverflow.ellipsis, style: TextStyle(color: sub, fontSize: 11))),
                ]),
              ]),
            ),
        ]),
      );
}
