import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/env.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Phone + SMS code inputs with the 60 s resend cooldown.
class PhoneCodeForm extends ConsumerStatefulWidget {
  const PhoneCodeForm({super.key, required this.submitLabel, required this.onSubmit, this.enabled = true});
  final String submitLabel;
  final Future<void> Function(String phone, String code) onSubmit;
  final bool enabled;

  @override
  ConsumerState<PhoneCodeForm> createState() => _PhoneCodeFormState();
}

class _PhoneCodeFormState extends ConsumerState<PhoneCodeForm> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  int _cooldown = 0;
  Timer? _timer;
  bool _sending = false, _busy = false;

  static final _phoneRe = RegExp(r'^1\d{10}$');

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _phoneOk => _phoneRe.hasMatch(_phone.text.trim());

  Future<void> _send() async {
    if (!_phoneOk) {
      toast(context, '请输入 11 位手机号');
      return;
    }
    setState(() => _sending = true);
    // TODO(人机验证): pass captcha_token from the Aliyun captcha SDK.
    final cd = await runGuarded(context, () => ref.read(apiProvider).sendSms(_phone.text.trim()));
    if (!mounted) return;
    setState(() => _sending = false);
    if (cd == null) return;
    toast(context, Env.isDev ? '验证码已发送（开发环境固定为 000000）' : '验证码已发送');
    setState(() => _cooldown = cd);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _submit() async {
    if (!_phoneOk || _code.text.trim().length < 4) {
      toast(context, '请输入手机号和验证码');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.onSubmit(_phone.text.trim(), _code.text.trim());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _phone,
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
        decoration: const InputDecoration(hintText: '手机号', prefixText: '+86  '),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            decoration: const InputDecoration(hintText: '验证码'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 4),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 56,
          child: OutlinedButton(
            onPressed: _cooldown > 0 || _sending ? null : _send,
            child: Text(_cooldown > 0 ? '${_cooldown}s' : '获取验证码'),
          ),
        ),
      ]),
      if (Env.isDev)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('开发环境：验证码固定 000000', style: TextStyle(color: LL.text3, fontSize: 12)),
        ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: !widget.enabled || _busy ? null : _submit,
        child: _busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Text(widget.submitLabel),
      ),
    ]);
  }
}
