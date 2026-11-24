import 'package:material_ui/material_ui.dart';

import '../audio/audio.dart';

/// [RefreshIndicator] that plays `ui_refresh` once the refresh is done.
class SoundRefresh extends StatelessWidget {
  const SoundRefresh({super.key, required this.onRefresh, required this.child});
  final RefreshCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: () async {
          final audio = audioOf(context);
          await onRefresh();
          audio?.play(Sounds.uiRefresh);
        },
        child: child,
      );
}
