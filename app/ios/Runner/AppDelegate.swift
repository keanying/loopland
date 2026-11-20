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
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 运营商一键登录（阿里云号码认证）。
    // TODO(一键登录): integrate the Aliyun 号码认证 iOS SDK (TXCommonHandler):
    // checkEnvAvailable → isAvailable, getLoginToken → getToken.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LooplandOneClick") {
      let channel = FlutterMethodChannel(name: "loopland/oneclick", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "isAvailable": result(false)
        case "getToken": result(FlutterError(code: "not_implemented", message: "一键登录 SDK 未集成", details: nil))
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
