import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../auth/auth_controller.dart';
import '../../auth/social_login.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'phone_code_form.dart';

/// 微信 / Apple 首次登录后必须绑定手机号（否则其他接口返回 403 phone_required）。
class BindPhonePage extends ConsumerStatefulWidget {
  const BindPhonePage({super.key});
  @override
  ConsumerState<BindPhonePage> createState() => _BindPhonePageState();
}

class _BindPhonePageState extends ConsumerState<BindPhonePage> {
  bool _oneClick = false;

  @override
  void initState() {
    super.initState();
    OneClickLogin().isAvailable().then((v) {
      if (mounted) setState(() => _oneClick = v);
    });
  }

  Future<void> _bindOneClick() async {
    await runGuarded(context, () async {
      final t = await OneClickLogin().getToken();
      if (t != null) await ref.read(authProvider.notifier).bindPhone(oneclickToken: t);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 32), children: [
          const Text('绑定手机号', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const Text('根据国家网络实名要求，使用前需要绑定手机号。手机号仅用于登录和安全验证，默认脱敏展示。',
              style: TextStyle(color: LL.text2, height: 1.6)),
          const SizedBox(height: 28),
          if (_oneClick) ...[
            FilledButton(onPressed: _bindOneClick, child: const Text('本机号码一键绑定')),
            const SizedBox(height: 20),
            const Center(child: Text('或使用验证码', style: TextStyle(color: LL.text3))),
            const SizedBox(height: 20),
          ],
          PhoneCodeForm(
            submitLabel: '绑定并继续',
            onSubmit: (phone, code) => runGuarded(
                context, () => ref.read(authProvider.notifier).bindPhone(phone: phone, code: code)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => ref.read(authProvider.notifier).logout(),
            child: const Text('换个账号登录', style: TextStyle(color: LL.text2)),
          ),
        ]),
      ),
    );
  }
}
