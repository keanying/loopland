import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

import '../../api/errors.dart';
import '../../auth/auth_controller.dart';
import '../../auth/social_login.dart';
import '../../core/env.dart';
import '../../core/theme.dart';
import '../../widgets/card_art.dart';
import '../../widgets/common.dart';

/// Shared by the login screens: the user-agreement checkbox state.
final agreedProvider = NotifierProvider<_Agreed, bool>(_Agreed.new);

class _Agreed extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

/// 登录注册：循环视频背景 + 一键登录 / 微信 / Apple / 其他手机号。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  /// Widget tests have no video platform; they turn this off.
  static bool enableVideo = true;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  VideoPlayerController? _video;
  bool _playing = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (LoginPage.enableVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final v = VideoPlayerController.asset('assets/media/login-bg.mp4',
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      _video = v;
      await v.initialize();
      await v.setLooping(true);
      await v.setVolume(0);
      if (_playing) await v.play();
      if (mounted) setState(() {});
    } catch (_) {
      _video = null; // poster stays
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() => _playing = !_playing);
    final v = _video;
    if (v == null || !v.value.isInitialized) return;
    _playing ? v.play() : v.pause();
  }

  /// Common pattern for Chinese apps: if the box is not ticked, ask once in
  /// a dialog (a snackbar would cover the checkbox itself).
  Future<bool> _checkAgreed() async {
    if (ref.read(agreedProvider)) return true;
    final ok = await confirmAgreement(context);
    if (ok) ref.read(agreedProvider.notifier).set(true);
    return ok;
  }

  Future<void> _login(Future<Map<String, dynamic>?> Function() credential, String provider) async {
    if (_busy || !await _checkAgreed()) return;
    setState(() => _busy = true);
    try {
      final c = await credential();
      if (c == null) return; // cancelled
      await ref.read(authProvider.notifier).login(provider, c);
    } catch (e) {
      if (mounted) await handleLoginError(context, ref, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _oneClick() => _login(() async {
        final t = await OneClickLogin().getToken();
        if (t == null) {
          if (mounted) context.push('/login/sms');
          return null;
        }
        return {'token': t};
      }, 'oneclick');

  Future<void> _wechat() => _login(() async {
        final code = await WeChat.authCode();
        return code == null ? null : {'code': code};
      }, 'wechat');

  Future<void> _apple() => _login(appleCredential, 'apple');

  @override
  Widget build(BuildContext context) {
    final agreed = ref.watch(agreedProvider);
    final v = _video;
    return Scaffold(
      body: Stack(fit: StackFit.expand, children: [
        Image.asset('assets/media/login-poster.jpg', fit: BoxFit.cover),
        if (v != null && v.value.isInitialized)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(width: v.value.size.width, height: v.value.size.height, child: VideoPlayer(v)),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x330E0E10), Color(0x000E0E10), Color(0xCC0E0E10), Color(0xFF0E0E10)],
              stops: [0, 0.35, 0.62, 0.8],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 16),
              Row(children: [
                const LoopMark(size: 40),
                const SizedBox(width: 10),
                const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('圈圈', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 1.1)),
                  Text('loopland', style: TextStyle(color: LL.lime, fontWeight: FontWeight.w800, height: 1.1)),
                ]),
                const Spacer(),
                RoundIconButton(
                  icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  onTap: _togglePlay,
                  color: const Color(0x99222226),
                  tooltip: _playing ? '暂停背景视频' : '播放背景视频',
                ),
              ]),
              const Spacer(),
              const Text('跑一圈，\n就是你的地',
                  style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, height: 1.2, letterSpacing: 1)),
              const SizedBox(height: 12),
              const Text('每一次跑步都在地图上圈下领地，和跑团一起建城、打怪兽。',
                  style: TextStyle(color: LL.text2, fontSize: 15, height: 1.6)),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: _busy ? null : _oneClick,
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Text('本机号码一键登录')),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _busy ? null : _wechat,
                  style: OutlinedButton.styleFrom(backgroundColor: const Color(0x66222226)),
                  child: const Text('微信登录'),
                ),
              ),
              if (Env.isIOS || Env.isDev) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _apple,
                    icon: const Icon(Icons.apple, size: 22),
                    style: OutlinedButton.styleFrom(backgroundColor: const Color(0x66222226)),
                    label: const Text('通过 Apple 登录'),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Center(
                child: TextButton(
                  onPressed: () => context.push('/login/sms'),
                  child: const Text('其他手机号登录 / 注册', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
              ),
              AgreementRow(agreed: agreed, onChanged: (v) => ref.read(agreedProvider.notifier).set(v)),
              const SizedBox(height: 12),
            ]),
          ),
        ),
      ]),
    );
  }
}

Future<bool> confirmAgreement(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('用户协议与隐私政策'),
        content: const Text('请阅读并同意《用户协议》《隐私政策》。圈圈会处理你的运动轨迹（敏感个人信息）用于圈地和排名。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('不同意', style: TextStyle(color: LL.text2))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('同意')),
        ],
      ),
    ) ==
    true;

class AgreementRow extends StatelessWidget {
  const AgreementRow({super.key, required this.agreed, required this.onChanged});
  final bool agreed;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!agreed),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 10),
          child: Semantics(
            checked: agreed,
            label: '同意用户协议和隐私政策',
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: agreed ? LL.lime : Colors.transparent,
                border: Border.all(color: agreed ? LL.lime : LL.text2, width: 1.5),
              ),
              child: agreed ? const Icon(Icons.check, size: 15, color: LL.ink) : null,
            ),
          ),
        ),
        const Expanded(
          child: Text.rich(
            TextSpan(style: TextStyle(color: LL.text3, fontSize: 13, height: 1.6), children: [
              TextSpan(text: '我已阅读并同意 '),
              TextSpan(text: '《用户协议》《隐私政策》', style: TextStyle(color: LL.lime)),
              TextSpan(text: '，并同意圈圈处理我的运动轨迹（敏感个人信息）用于圈地和排名'),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Login error handling. (Accounts in the 7-day deletion cooling-off can log
/// in normally; the app shows「账号注销中」with an undo button afterwards.)
Future<void> handleLoginError(BuildContext context, WidgetRef ref, Object e) async {
  final ex = ApiException.from(e);
  if (ex.code == 'cancelled') return;
  showError(context, ex);
}
