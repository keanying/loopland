# 圈圈 release (R8) keep rules for the native SDKs. Each block follows the
# vendor's documented rules; the SDK AARs also ship consumer rules, these are
# kept explicitly so a vendor AAR without them does not break release builds.

# ── Flutter ──
-dontwarn com.google.android.play.core.**
-keep class io.flutter.plugins.** { *; }

# ── 微信 OpenSDK（fluwx）──  https://developers.weixin.qq.com/doc/oplatform/Mobile_App/Access_Guide/Android.html
-keep class com.tencent.mm.opensdk.** { *; }
-keep class com.tencent.wxop.** { *; }
-keep class com.tencent.mm.sdk.** { *; }
-keep class com.jarvan.fluwx.** { *; }

# ── 支付宝 SDK（tobias）──  https://opendocs.alipay.com/open/204/105296
-keep class com.alipay.android.app.IAlixPay{*;}
-keep class com.alipay.android.app.IAlixPay$Stub{*;}
-keep class com.alipay.android.app.IRemoteServiceCallback{*;}
-keep class com.alipay.android.app.IRemoteServiceCallback$Stub{*;}
-keep class com.alipay.sdk.app.PayTask{ public *;}
-keep class com.alipay.sdk.app.AuthTask{ public *;}
-keep class com.alipay.sdk.app.H5PayCallback {
    <fields>;
    <methods>;
}
-keep class com.alipay.android.phone.mrpc.core.** { *; }
-keep class com.alipay.apmobilesecuritysdk.** { *; }
-keep class com.alipay.mobile.framework.service.annotation.** { *; }
-keep class com.alipay.mobilesecuritysdk.face.** { *; }
-keep class com.alipay.tscenter.biz.rpc.** { *; }
-keep class org.json.alipay.** { *; }
-keep class com.alipay.tscenter.** { *; }
-keep class com.ta.utdid2.** { *;}
-keep class com.ut.device.** { *;}
-keep class com.jarvan.tobias.** { *; }
-dontwarn com.alipay.**
-dontwarn com.ta.utdid2.**
-dontwarn com.ut.device.**

# ── 高德 3D 地图 + 定位 + 搜索（amap_map）──  https://lbs.amap.com/api/android-sdk/guide/create-project/dev-attention
-keep class com.amap.api.maps.**{*;}
-keep class com.autonavi.**{*;}
-keep class com.amap.api.trace.**{*;}
-keep class com.amap.api.location.**{*;}
-keep class com.amap.api.fence.**{*;}
-keep class com.loc.**{*;}
-keep class com.autonavi.aps.amapapi.model.**{*;}
-keep class com.amap.api.services.**{*;}
-keep class com.amap.flutter.**{*;}
-dontwarn com.amap.api.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**

# ── 阿里云号码认证（ali_auth，auth_number_product AAR）──  https://help.aliyun.com/zh/pnvs/
-keepattributes Exceptions,InnerClasses,Signature,Deprecated,*Annotation*,EnclosingMethod
-keep class cn.com.chinatelecom.** {*;}
-keep class com.cmic.sso.sdk.** {*;}
-keep class com.cmic.gen.sdk.** {*;}
-keep class com.mobile.auth.** {*;}
-keep class com.nirvana.** {*;}
-keep class * implements com.nirvana.tools.jsoner.Jsoner {*;}
-keep class com.alicom.tools.serialization.* {*;}
-keep class com.alicom.tools.networking.* {*;}
-keep class * implements com.alicom.tools.serialization.JSONer {*;}
-keep class com.unicom.online.account.shield.** {*;}
-keepclasseswithmembernames class * {
    native <methods>;
}
-dontwarn com.mobile.auth.**
-dontwarn com.cmic.sso.sdk.utils.**
-dontwarn com.cmic.gen.sdk.**
-dontwarn com.nirvana.**
-dontwarn com.unicom.online.account.kernel.**
# The plugin (and its fastjson2 dependency, used reflectively).
-keep class com.sean.rao.ali_auth.** { *; }
-keep class com.alibaba.fastjson2.** { *; }
-dontwarn com.alibaba.fastjson2.**

# ── safe_device（RootBeer）──
-keep class com.scottyab.rootbeer.** { *; }
-dontwarn com.scottyab.rootbeer.**
