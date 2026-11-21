import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/social_login.dart';
import '../map/amap_map.dart';
import '../pay/payment_service.dart';
import 'privacy.dart';
import 'sdk_config.dart';

/// Third-party SDK initialisation, deferred until the first-launch privacy
/// agreement ([LaunchPrivacy]). Nothing here runs before that.
class SdkBootstrap {
  SdkBootstrap._();
  static bool _done = false;

  static void install(ProviderContainer container) {
    SdkConfig.current.logMissing();
    LaunchPrivacy.onAgreed = () => _afterPrivacy(container);
  }

  static void _afterPrivacy(ProviderContainer c) {
    if (_done || kIsWeb) return;
    _done = true;
    final cfg = SdkConfig.current;
    // 高德：updatePrivacyShow / updatePrivacyAgree before any map is created.
    AmapTerritoryMap.agreePrivacy();
    // 微信：registerApi(WECHAT_APP_ID, WECHAT_UNIVERSAL_LINK).
    WeChat.ensureRegistered().ignore();
    // StoreKit: verify renewals / interrupted purchases with the server.
    if (cfg.isIOS) c.read(paymentServiceProvider).startAppleListener();
  }
}
