package com.loopland.loopland

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 运营商一键登录（阿里云号码认证）。
        // TODO(一键登录): integrate the Aliyun 号码认证 Android SDK
        // (PhoneNumberAuthHelper): checkEnvAvailable → isAvailable,
        // getLoginToken → getToken. Until then the Dart side falls back to SMS.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "loopland/oneclick")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAvailable" -> result.success(false)
                    "getToken" -> result.error("not_implemented", "一键登录 SDK 未集成", null)
                    else -> result.notImplemented()
                }
            }
    }
}
