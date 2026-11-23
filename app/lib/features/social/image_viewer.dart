import 'package:material_ui/material_ui.dart';

import '../../api/community_models.dart';
import '../../core/theme.dart';
import '../../widgets/l_icons.dart';
import 'social_widgets.dart';

/// Full-screen swipe viewer with pinch zoom.
Future<void> showImageViewer(BuildContext context, List<PostImage> images, int index) =>
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, _, _) => ImageViewer(images: images, initial: index),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));

class ImageViewer extends StatefulWidget {
  const ImageViewer({super.key, required this.images, this.initial = 0});
  final List<PostImage> images;
  final int initial;
  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late final _ctrl = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _ctrl,
          itemCount: n,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: Hero(
                  tag: 'img-${widget.images[i].url}-$i',
                  child: NetImage(url: widget.images[i].url, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const LIcon(LIcons.close, color: LL.text),
              ),
              const Spacer(),
              if (n > 1)
                Text('${_i + 1} / $n', style: const TextStyle(color: LL.text, fontWeight: FontWeight.w800)),
              const SizedBox(width: 12),
            ]),
          ),
        ),
      ]),
    );
  }
}
