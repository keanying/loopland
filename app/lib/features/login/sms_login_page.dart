import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../auth/auth_controller.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import 'login_page.dart';
import 'phone_code_form.dart';

class SmsLoginPage extends ConsumerWidget {
  const SmsLoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agreed = ref.watch(agreedProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          const BackHeader(title: '手机号登录', subtitle: '未注册的手机号验证后自动创建账号'),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PhoneCodeForm(
                submitLabel: '登录 / 注册',
                onSubmit: (phone, code) async {
                  if (!ref.read(agreedProvider)) {
                    toast(context, '请先阅读并同意《用户协议》《隐私政策》');
                    return;
                  }
                  try {
                    await ref.read(authProvider.notifier).login('sms', {'phone': phone, 'code': code});
                  } catch (e) {
                    if (context.mounted) await handleLoginError(context, ref, e);
                  }
                },
              ),
              const SizedBox(height: 20),
              AgreementRow(agreed: agreed, onChanged: (v) => ref.read(agreedProvider.notifier).set(v)),
              const SizedBox(height: 24),
              const Text('登录即代表你年满 14 周岁，或已取得监护人同意。', style: TextStyle(color: LL.text3, fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}
