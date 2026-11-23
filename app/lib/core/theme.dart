import 'package:material_ui/material_ui.dart';

import '../widgets/l_icons.dart';

/// Brand palette (docs/资料包/04_Logo与图标/README.md).
class LL {
  LL._();

  static const night = Color(0xFF0E0E10); // 夜跑黑
  static const lime = Color(0xFFDCF26A); // 荧光绿
  static const lavender = Color(0xFFB4A3F5); // 薰衣紫
  static const ink = Color(0xFF121212);
  static const card = Color(0xFF1B1B20);
  static const card2 = Color(0xFF24242A);
  static const border = Color(0xFF2C2C33);
  static const text = Color(0xFFF4F4F5);
  static const text2 = Color(0xFFB5B5BE);
  static const text3 = Color(0xFF8A8A94);
  static const pink = Color(0xFFF28DC0);
  static const orange = Color(0xFFFF9F5A);
  static const red = Color(0xFFFF5A6E);
  static const sky = Color(0xFF6FD3E8);
  static const yellow = Color(0xFFFFC857);

  static const double radius = 24;

  /// CJK fallbacks for explicit TextStyles (buttons, map labels).
  static const fonts = ['PingFang SC', 'Noto Sans SC', 'Noto Sans CJK SC', 'sans-serif'];
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: LL.lime,
    onPrimary: LL.ink,
    secondary: LL.lavender,
    onSecondary: LL.ink,
    surface: LL.night,
    onSurface: LL.text,
    error: LL.red,
    surfaceContainerHighest: LL.card2,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: LL.night,
    fontFamilyFallback: LL.fonts,
  );
  return base.copyWith(
    // Material 自带的返回 / 关闭按钮（如 AppBar 自动加的返回）也用圈圈自己的图标
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const LIcon(LIcons.back),
      closeButtonIconBuilder: (_) => const LIcon(LIcons.close),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: LL.night,
      foregroundColor: LL.text,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: LL.text),
    ),
    cardTheme: CardThemeData(
      color: LL.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LL.radius),
        side: const BorderSide(color: LL.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: LL.lime,
        foregroundColor: LL.ink,
        disabledBackgroundColor: LL.card2,
        minimumSize: const Size(64, 52),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, fontFamilyFallback: LL.fonts),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: LL.text,
        minimumSize: const Size(64, 52),
        side: const BorderSide(color: Color(0x55F4F4F5)),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, fontFamilyFallback: LL.fonts),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: LL.lime),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: LL.card,
      hintStyle: const TextStyle(color: LL.text3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: LL.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: LL.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: LL.lime),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: LL.card,
      showDragHandle: true,
      dragHandleColor: LL.text3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: LL.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LL.radius)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: LL.card2,
      contentTextStyle: TextStyle(color: LL.text),
      behavior: SnackBarBehavior.floating,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? LL.ink : LL.text3),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? LL.lime : LL.card2),
    ),
    dividerTheme: const DividerThemeData(color: LL.border, space: 1),
    tabBarTheme: const TabBarThemeData(
      labelColor: LL.ink,
      unselectedLabelColor: LL.text2,
      dividerColor: Colors.transparent,
    ),
  );
}
