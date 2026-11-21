import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';

/// Opens the in-app scanner and returns the first QR content (or null).
/// Overridden in tests.
typedef QrScanner = Future<String?> Function(BuildContext context);

final qrScannerProvider = Provider<QrScanner>((ref) => (context) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage(), fullscreenDialog: true)));

/// 扫一扫：场馆二维码（`LPV.<id>.<签名>` 或 `https://<域名>/v/<内容>`）。
/// mobile_scanner asks for the camera permission itself; the permission
/// texts are in AndroidManifest / Info.plist.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key, this.title = '扫场馆二维码', this.hint = '对准场馆前台或球场边的圈圈二维码'});
  final String title, hint;
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _done = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture c) {
    if (_done) return;
    final v = c.barcodes.map((b) => b.rawValue).whereType<String>().where((s) => s.isNotEmpty).firstOrNull;
    if (v == null) return;
    _done = true;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _ctrl,
            onDetect: _onDetect,
            errorBuilder: (context, e) => _error(e),
          ),
        ),
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _FramePainter()))),
        SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
              Expanded(
                child: Text(widget.title,
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
              ),
              IconButton(
                onPressed: () => _ctrl.toggleTorch(),
                icon: const Icon(Icons.flashlight_on_outlined, color: Colors.white),
                tooltip: '手电筒',
              ),
            ]),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: Text(widget.hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _error(MobileScannerException e) {
    final text = switch (e.errorCode) {
      MobileScannerErrorCode.permissionDenied => '没有相机权限。请在系统设置里允许圈圈使用相机，或改用定位签到。',
      MobileScannerErrorCode.unsupported => '这台设备不支持扫码，请改用定位签到。',
      _ => '相机打开失败（${e.errorCode.name}），请稍后再试或改用定位签到。',
    };
    return ColoredBox(
      color: LL.night,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: LL.text2, height: 1.6)),
        ),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final side = size.width * 0.66;
    final r = Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side);
    final bg = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(r, const Radius.circular(24)));
    canvas.drawPath(bg, Paint()..color = const Color(0x99000000));
    canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(24)),
        Paint()
          ..color = LL.lime
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
