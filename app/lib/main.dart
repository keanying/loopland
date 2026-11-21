import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/sdk_bootstrap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(retry: noRetry);
  // Logs missing keys (release builds hide those options) and defers every
  // SDK init until the user accepted the first-launch privacy dialog.
  SdkBootstrap.install(container);
  runApp(UncontrolledProviderScope(container: container, child: const LooplandApp()));
}
