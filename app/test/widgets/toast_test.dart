import 'package:flutter_test/flutter_test.dart';
import 'package:loopland/core/theme.dart';
import 'package:loopland/widgets/common.dart';
import 'package:material_ui/material_ui.dart';

import 'test_helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('轻提示：顶部悬浮、在底部面板之上、不挡点击、自动收起', (t) async {
    await phone(t);
    var tapped = 0;
    late BuildContext ctx;
    await t.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: MaterialApp(
        theme: buildTheme(),
        debugShowCheckedModeBanner: false,
        home: Builder(builder: (c) {
          ctx = c;
          return Scaffold(
            backgroundColor: LL.night,
            body: Align(
              alignment: const Alignment(0, -0.82),
              child: FilledButton(onPressed: () => tapped++, child: const Text('顶部按钮')),
            ),
          );
        }),
      ),
    ));
    // 打开一个底部面板，再从面板里弹提示（截图里的场景：宝箱面板 + 拿不到定位）
    showModalBottomSheet<void>(
      context: ctx,
      builder: (c) => SizedBox(
        height: 260,
        child: Center(
          child: FilledButton(onPressed: () => toast(c, '暂时拿不到定位，到开阔的地方再试试', kind: ToastKind.warning), child: const Text('走过去打开')),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('走过去打开'));
    await t.pump(); // 动画从这一帧开始计时
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('暂时拿不到定位，到开阔的地方再试试'), findsOneWidget);
    await screenshot(t, find.byKey(const Key('shot')), 'screenshots/v2/toast.png');

    // 面板的主按钮没有被挡住：还能点
    await t.tap(find.text('走过去打开'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('暂时拿不到定位，到开阔的地方再试试'), findsOneWidget); // 新的替换旧的，仍然只有一条

    // 自动收起（停留 1.8 秒 + 每字 60 毫秒，最多 5 秒）
    await t.pump(const Duration(seconds: 5));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('暂时拿不到定位，到开阔的地方再试试'), findsNothing);

    // 不拦截点击：提示盖在顶部按钮上时，按钮照常能点
    Navigator.of(ctx).pop();
    await t.pumpAndSettle();
    toast(ctx, '已保存，审核中（未通过会恢复默认并通知你）', kind: ToastKind.success);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('顶部按钮'), warnIfMissed: false);
    expect(tapped, 1);
    dismissToast();
    await settle(t);
  });
}
