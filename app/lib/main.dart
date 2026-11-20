import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'auth/social_login.dart';
import 'core/env.dart';
import 'core/providers.dart';
import 'pay/payment_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(retry: noRetry);
  if (!kIsWeb) {
    WeChat.ensureRegistered().ignore();
    if (Env.isIOS) container.read(paymentServiceProvider).startAppleListener();
  }
  runApp(UncontrolledProviderScope(container: container, child: const LooplandApp()));
}
