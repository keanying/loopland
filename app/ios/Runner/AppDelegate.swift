import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // 一键登录（ali_auth）、微信（fluwx，含 UIScene openURL / Universal Link 回调）、
    // 支付宝（tobias）、内购（in_app_purchase_storekit）都由插件自行注册。
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
