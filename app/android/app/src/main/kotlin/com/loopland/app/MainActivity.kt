package com.loopland.app

import io.flutter.embedding.android.FlutterActivity

// 一键登录（ali_auth）、微信（fluwx）、支付宝（tobias）均由插件自行注册，
// 不需要在这里写 MethodChannel。微信回调 Activity 由 fluwx 的 manifest 以
// activity-alias 提供：${applicationId}.wxapi.WXEntryActivity / WXPayEntryActivity。
class MainActivity : FlutterActivity()
