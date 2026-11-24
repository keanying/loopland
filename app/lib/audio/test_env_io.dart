import 'dart:io' show Platform;

/// `flutter test` sets FLUTTER_TEST: no real audio (and no platform channels)
/// in unit / widget tests.
bool get isFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');
