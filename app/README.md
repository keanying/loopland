# 圈圈 Loopland · App（V1）

Flutter 3 + Riverpod 客户端。接口约定以 `docs/api/v1.md` 为准，只实现 V1 范围的功能；V2 的入口（场馆、组局、赛事、动态、怪兽图鉴等）显示「即将开放」。

## 环境

- Flutter 3.50.x stable（Dart 3.14）。依赖版本全部锁定在 `pubspec.yaml`。
- 注意：Flutter 3.47 起 `package:flutter/material.dart` 已废弃，本项目统一使用 `package:material_ui/material_ui.dart`。

```bash
cd app
flutter pub get
flutter analyze          # 应为 No issues found
flutter test             # 单元测试 + 组件测试
LOOPLAND_SCREENSHOTS=1 flutter test test/widgets   # 顺便把截图写到 screenshots/
```

运行（开发后端 `LOOPLAND_ENV=dev`）：

```bash
flutter run --dart-define=LOOPLAND_ENV=dev --dart-define=API_BASE=http://192.168.1.10:8080
```

## 配置（dart-define）

所有 Key / ID 都在构建时注入，**仓库里没有任何真实密钥**。Dart 侧用 `--dart-define-from-file`：

```bash
cp config/dev.json.example config/dev.json      # 已 gitignore
flutter run --dart-define-from-file=config/dev.json
cp config/prod.json.example config/prod.json    # 已 gitignore，填真实值
flutter build apk --release --dart-define-from-file=config/prod.json
```

| 变量 | 说明 |
| --- | --- |
| `LOOPLAND_ENV` | `dev`：验证码 000000 提示、`mock` 支付、「环境检查」页；未配置 SDK 时一键登录 / 微信用开发后端的 `dev:` 凭证。默认 `prod` |
| `API_BASE` | 后端地址。默认 Android 模拟器 `http://10.0.2.2:8080`，其他 `http://localhost:8080`（release 包只允许 HTTPS） |
| `ALIYUN_AUTH_SECRET_ANDROID` / `_IOS` | 阿里云号码认证「方案秘钥」，两个平台各一个 |
| `WECHAT_APP_ID` / `WECHAT_UNIVERSAL_LINK` | 微信开放平台 AppID；iOS Universal Link（`https://域名/路径/`） |
| `ALIPAY_APP_ID` / `ALIPAY_UNIVERSAL_LINK` | 可选（支付宝风控优化 / iOS Universal Link）。支付只用服务端返回的 `order_string` |
| `AMAP_ANDROID_KEY` / `AMAP_IOS_KEY` | 高德 Key。没有 Key 时使用纯 Flutter 备用地图 |
| `AMAP_STYLE_DATA` / `AMAP_STYLE_EXTRA_DATA` | 高德暗色自定义样式文件的 asset 路径（如 `assets/map/style.data`），可选 |
| `ALIYUN_CAPTCHA_PREFIX` / `ALIYUN_CAPTCHA_SCENE_ID` | 阿里云验证码 2.0 身份标与场景 ID；不配置时（开发）跳过人机验证 |
| `USER_AGREEMENT_URL` / `PRIVACY_POLICY_URL` | 用户协议 / 隐私政策链接（启动隐私弹窗、登录页、一键登录授权页、设置页） |

模板里 `<...>` 形式的占位符按「未配置」处理。原生文件需要的值另外放在：

| 文件（均 gitignore） | 模板 | 内容 |
| --- | --- | --- |
| `android/key.properties` | `android/key.properties.example` | release 签名：`storeFile`（相对 `android/`）、`storePassword`、`keyAlias`、`keyPassword` |
| `android/loopland.properties` | `android/loopland.properties.example` | `AMAP_ANDROID_KEY` → manifest `com.amap.api.v2.apikey`（留空时回退到 dart-define 同名值） |
| `ios/Flutter/Loopland.xcconfig` | `ios/Flutter/Loopland.xcconfig.example` | `WECHAT_APP_ID`（URL Type）、`ALIPAY_URL_SCHEME`（默认 `loopland-alipay`）、`LOOPLAND_ASSOCIATED_DOMAIN`（Associated Domains）、可选 `DEVELOPMENT_TEAM` |

`ios/Flutter/Debug.xcconfig` / `Release.xcconfig` 依次 include `LooplandDefaults.xcconfig`（已提交的默认值）和可选的 `Loopland.xcconfig`。注意 xcconfig 里 `//` 是注释，只写域名 / scheme。

### 配置校验与服务端开关

- 启动时 `SdkConfig.logMissing()` 记录缺少的 Key（日志名 `loopland.config`），**release 包隐藏**缺 Key 的登录 / 支付入口而不是崩溃；debug 包仍显示入口，点了给出明确提示。
- 登录方式、支付渠道还要与服务端 `GET /v1/config/features` 取交集（会话内缓存）；请求失败时只显示短信登录，下次打开登录页重试。`captcha=true` 时发短信前显示人机验证。
- 开发环境（`LOOPLAND_ENV=dev`）登录页右上角和「设置」里有「环境检查」页：各 SDK 是否配置、服务端 features、最终显示哪些入口、设备风控检测结果。

## 目录

```
lib/
  api/        接口模型（手写 fromJson，容错）、dio 客户端（Bearer、X-Platform、refresh token 单飞轮换）、错误码中文文案
  auth/       token 存储（flutter_secure_storage）、登录状态、一键登录（ali_auth）、人机验证（WebView）、微信、Apple
  core/       SdkConfig（所有 Key）、/v1/config/features、启动隐私弹窗、SDK 延迟初始化、主题
  features/debug/  环境检查页（仅 dev）
  claim/      geo.go / claim.go 的 Dart 移植（圈地预览、「还差 X 米可闭合」），WGS-84→GCJ-02
  run/        定位源（geolocator）、运动记录状态机、离线存储与重传
  map/        TerritoryMapView 抽象：高德实现 + 备用 CustomPainter 实现
  pay/        微信 / 支付宝 / Apple 内购 / mock，下单后轮询订单
  features/   各页面
test/         claim 测试（Go 测试原样移植）、接口 JSON 解析（契约示例）、客户端、运动记录、组件测试
screenshots/  组件测试生成的界面截图
```

## 已实现

- 登录注册：视频背景登录页、本机号码一键登录（阿里云号码认证，失败自动转短信）、人机验证、短信验证码、微信、Apple；协议勾选；`need_bind_phone` → 绑定手机号；隐私授权页（隐私政策 + 位置/行踪轨迹 + 运动健康数据分开授权），第一次户外运动前强制检查位置授权；注销冷静期账号登录后提示「账号注销中」并可撤回。
- 任意接口返回 `403 phone_required` → 绑定手机号；`consent_required` → 授权页；`account_banned` → 退出登录；`401` → 自动用 refresh token 轮换（并发请求共享一次刷新），失败才退出。
- 领地：地图首页（全城 / 我的 / 跑团、按视野 bbox 加载、点领地弹卡片：去建设 / 导航去抢 / 高德导航、缩放与定位按钮、铃铛进消息）。
- 建城：6 个建造位、建筑选择（费用 / 守卫 / 产能 / 解锁等级 / 能量不足）、角色派驻与撤下、实时守卫值和每日能量。
- 图鉴：角色 / 建筑 / 伙伴 / 怪兽（即将开放）/ 奖牌；三列卡片，未获得显示剪影 + 问号和解锁方式；详情弹层；孵化的伙伴设为陪跑。卡牌插画从原型 `CardArt.dc.html` 提取为 `assets/art/*.svg`。
- 开始：户外 GPS（跑步 / 骑行 / 徒步 / 健走，目标：自由 / 距离 / 时间 / 抢指定领地）、居家训练（力量 / 瑜伽 / HIIT 计时，跳绳计数）、场馆运动显示 V2。
- 运动中：3-2-1 倒计时、实时轨迹、本地圈地预览（移植的 claim 算法）、「还差 X 米可闭合」虚线提示、距离 / 配速 / 时长 / 已圈面积、暂停继续、长按结束、模拟定位提示、Android 前台服务常驻通知 / iOS 后台定位。
- 结算页：圈地、攻击（守卫变化）、能量（含每日上限提示）、升级、招募进度、伙伴蛋、奖牌、复核 / 作废说明。
- 社区（V1）：我的跑团卡片与本周排行、找跑团、创建、加入 / 申请、退出、团长管理（成员、踢人、转让、审批申请）。
- 我的：资料与本周数据、领地、图鉴精选、待上传记录、运动记录列表与详情（轨迹）、会员（套餐、渠道、下单、轮询、自动续费开关；未成年不展示）、设置（轨迹可见范围、隐藏起终点、地图头像、个性化、授权、实名、导出数据、注销与撤回、退出）、站内消息（分类、单条 / 全部已读）。
- 离线：进行中的运动每 5 秒和每次暂停写入 `runs/in_progress.json`（先写临时文件再改名）；结束后先写入 `runs/pending/<client_id>.json` 再上传；启动时提示恢复中断的运动并补传，补传使用相同 `client_id`（服务端幂等）。

## 坐标系

接口和高德都使用 GCJ-02。geolocator 拿到的是系统 GPS 的 WGS-84，记录时统一用 `lib/claim/gcj02.dart` 转换后再上传和绘制。若以后换成高德定位 SDK（直接给 GCJ-02），去掉这一步即可。

## 接入真实 SDK

应用 ID：Android `applicationId` / iOS Bundle ID 均为 **`com.loopland.app`**。

### 隐私合规（所有 SDK 的前提）

首次启动先显示「欢迎使用圈圈」隐私弹窗（`lib/core/privacy.dart`，版本号 `Env.privacyVersion`，变更后重新弹出）。**同意之前**不初始化任何第三方 SDK、不调用 geolocator、地图只用备用渲染；同意后 `SdkBootstrap` 才依次：高德 `updatePrivacyShow/updatePrivacyAgree` → 微信 `registerApi` → StoreKit 交易监听。一键登录、人机验证只在用户主动点击时才加载。登录后的「隐私与授权」页（位置 / 健康单独授权）照旧。

### 签名证书指纹（微信 / 支付宝 / 高德 / 号码认证都要填）

```bash
# 生成 release keystore（只做一次，妥善备份；丢失后无法更新应用）
keytool -genkeypair -v -keystore android/app/loopland-release.jks -alias loopland \
  -keyalg RSA -keysize 2048 -validity 36500
# 查看指纹
keytool -list -v -keystore android/app/loopland-release.jks -alias loopland
```

- **微信开放平台**「应用签名」：release 证书 **MD5，去掉冒号、小写**，如 `keytool` 输出 `AB:CD:…` → `abcd…`。也可装微信的「签名生成工具」（GenSignature）对已安装的 release 包取值。debug 包签名不同，微信会返回 `errCode -1`。
- **高德控制台**「发布版安全码 SHA1」：release 证书 **SHA1（带冒号）**＋包名 `com.loopland.app`；调试版 SHA1 用 `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android`。
- **支付宝开放平台**：应用信息里填 **应用签名 MD5**（同微信的取法，去冒号小写）＋包名。
- **阿里云号码认证** Android 方案：包名＋**签名 MD5**（去冒号小写；也可用阿里云提供的 AppSignGet 工具）。iOS 方案填 Bundle ID。
- 上架应用市场若使用「平台代签名」（如华为 / Google Play App Signing），以**平台最终签名**的指纹为准。

### 1. 阿里云号码认证（一键登录）— `ali_auth 1.4.0`

- 申请：阿里云控制台 → 号码认证服务 → 号码认证方案管理，Android、iOS 各建一个方案，得到两个**方案秘钥**。
- 配置：`config/prod.json` 的 `ALIYUN_AUTH_SECRET_ANDROID` / `ALIYUN_AUTH_SECRET_IOS`。
- 实现：`lib/auth/one_click.dart`。`initSdk(isDelay)` → 终端检查（600024）→ `login` 拉起授权页 → 600000 拿 token → `POST /v1/auth/login provider=oneclick`（绑定手机号时为 `oneclick_token`）。无 SIM、只开 Wi‑Fi、运营商维护、秘钥错误、超时等任何失败都提示原因并转到短信登录，不会崩溃。只有 `LOOPLAND_ENV=dev` 且未配置秘钥时才用 `dev:13800138000`。
- 授权页：全屏深色 `#0E0E10`、荧光绿 `#DCF26A` 登录按钮、Logo（`assets/brand/auth_logo.png`）、slogan、「其他手机号登录」、运营商协议＋《用户协议》《隐私政策》（URL 来自 dart-define），协议**不默认勾选**，未勾选点登录时弹二次确认。
- 合规：插件自带的 `READ_PHONE_STATE`、`WRITE_EXTERNAL_STORAGE` 已在 manifest 中 `tools:node="remove"`；插件开启的明文流量在 release 中关闭。
- iOS：插件 podspec 已加 `-ObjC`；**不要**再手动把 ATAuthSDK.framework 拖进工程。

### 2. 微信（登录 / 支付）— `fluwx 6.0.6`

- 申请：微信开放平台 → 移动应用（Android 包名＋签名 MD5；iOS Bundle ID＋Universal Link），开通「微信登录」，商户平台开通 APP 支付并关联 AppID。
- 配置：`config/prod.json` 的 `WECHAT_APP_ID`、`WECHAT_UNIVERSAL_LINK`；`ios/Flutter/Loopland.xcconfig` 的 `WECHAT_APP_ID`、`LOOPLAND_ASSOCIATED_DOMAIN`；服务器 `https://<域名>/.well-known/apple-app-site-association` 中加入 `<TeamID>.com.loopland.app` 和对应路径。
- Android：fluwx 的 manifest 已用 activity-alias 声明 `com.loopland.app.wxapi.WXEntryActivity` / `WXPayEntryActivity`，并有 `<queries><package com.tencent.mm/>`，无需自写 Activity。
- iOS：Info.plist URL Type `weixin` = `$(WECHAT_APP_ID)`；`LSApplicationQueriesSchemes` 含 `weixin`、`weixinULAPI`、`weixinURLParamsAPI`；`Runner.entitlements` 的 Associated Domains = `applinks:$(LOOPLAND_ASSOCIATED_DOMAIN)`。
- 登录用 `snsapi_userinfo`；支付把服务端 `pay_params` 的 `appid / partnerid / prepayid / package / noncestr / timestamp / sign` 原样传给 SDK（缺字段直接报错，不下发）。未安装微信时提示「未安装微信…」，且**不会先创建订单**。

### 3. 支付宝 — `tobias 6.0.0`

- 申请：支付宝开放平台创建应用，开通「APP 支付」，填应用签名＋包名；密钥在服务端，App 只拿 `order_string`。
- iOS：Info.plist URL Type `alipay` = `$(ALIPAY_URL_SCHEME)`（Loopland.xcconfig，默认 `loopland-alipay`，不能含下划线；tobias 按 URLName `alipay` 找它）；`LSApplicationQueriesSchemes` 含 `alipay`、`alipays`。（API 约定 iOS 只能用 Apple 内购，这里的配置是为以后 / 审核外渠道预留。）
- 支付后**无论 SDK 返回什么**都会轮询 `GET /v1/orders/{no}`：9000 / 8000 / 6004 等待回调直到 `paid`；6001 取消或失败时也再查几秒，服务端说已支付就算成功。

### 4. Apple（登录 / 内购）— `sign_in_with_apple`、`in_app_purchase 3.3.1`（`in_app_purchase_storekit 0.4.17`）

- Xcode → Runner → Signing & Capabilities：打开 **Sign in with Apple**、**In-App Purchase**、**Associated Domains**、**Background Modes → Location updates**（`Runner/Runner.entitlements` 已包含前两项的 entitlement；In‑App Purchase 没有 entitlement key，但要在 App ID 上开启）。
- App Store Connect：建立与 `apple_product_id` 一致的自动续期订阅；配置 App Store Server Notifications V2 指向 `POST /v1/pay/notify/apple`。
- 内购：`applicationUserName` = 下单返回的 `app_account_token`（StoreKit 2 `appAccountToken`）。storekit 插件 0.4.x 默认 StoreKit 2，`serverVerificationData` 就是交易的 **`jwsRepresentation`**，发到 `POST /v1/iap/apple`；**服务端返回 200 后才 `finishTransaction`**，校验失败不 finish（StoreKit 下次启动重发）。拿到的不是 JWS（旧版收据）时不发送并提示。最低系统 iOS 15（StoreKit 2）。
- 会员页有「恢复购买」按钮（`restorePurchases` → 逐笔 JWS 验证）。

### 5. 高德地图 — `amap_map 1.0.15`

- 申请：高德开放平台 → 应用管理，分别添加 Android Key（包名＋发布版 / 调试版 SHA1）和 iOS Key（Bundle ID）。
- 配置：Android Key 进 `android/loopland.properties`（或 dart-define）→ manifestPlaceholders → `com.amap.api.v2.apikey`；Dart 的 `AMAP_ANDROID_KEY` / `AMAP_IOS_KEY` 通过插件 `AMapInitializer.init(apiKey:)` 传给 SDK（iOS 只走这一路）。
- 隐私合规：只有用户同意启动隐私弹窗后才调用 `AMapInitializer.updatePrivacyAgree`（插件在创建地图时转成 SDK 的 `updatePrivacyShow/updatePrivacyAgree`），之前一律显示备用地图；geolocator 同样在同意前不启动，户外运动前还要求「位置信息与行踪轨迹」授权。
- 暗色样式：高德控制台「自定义地图」发布后下载 `style.data` / `style_extra.data`，放进 `assets/map/`，在 `config/prod.json` 设 `AMAP_STYLE_DATA=assets/map/style.data`、`AMAP_STYLE_EXTRA_DATA=assets/map/style_extra.data`，地图自动启用 `customStyleOptions`；否则用内置 `MapType.night`。
- iOS 需要 `pod install`。

### 6. 阿里云验证码 2.0（人机验证）— `webview_flutter`

- 申请：阿里云验证码 2.0 控制台 → 新建场景（**V3 架构**，即验证参数随业务请求一起提交、由服务端 VerifyIntelligentCaptcha 校验），拿到**身份标 prefix** 和**场景 ID**。服务端配置同一场景的 AccessKey。
- 配置：`ALIYUN_CAPTCHA_PREFIX`、`ALIYUN_CAPTCHA_SCENE_ID`。
- 实现：`lib/auth/captcha.dart` 在 WebView 里加载 `AliyunCaptcha.js`（`AliyunCaptchaConfig = {region: "cn", prefix}`，`initAliyunCaptcha({SceneId, mode: "embed", success})`），`success(captchaVerifyParam)` 经 JS Channel 回传，作为 `captcha_token` 调 `POST /v1/auth/sms/send`。服务端 `features.captcha=false` 时跳过；为 true 但 App 未配置时提示「人机验证未配置」，不发请求。`captcha_failed` 有中文提示。

### 7. 设备风控 — `safe_device 1.4.1`

`device.rooted`（Android RootBeer / iOS DTTJailbreakDetection）、`device.emulator`（device_info_plus ＋ safe_device）、`device.multi_open`（应用私有目录不是 `/data/user/0/com.loopland.app`：MIUI/ColorOS 双开 999、三星 95、VirtualApp/平行空间等容器）。safe_device 的模拟定位检测已关闭（会触发定位）；模拟定位由 geolocator 的 `isMocked` 逐点上报。多开是启发式判断，工作资料（work profile）也会被标记，服务端只作为风险信号使用。

### Android release 构建

- `signingConfigs.release` 读 `android/key.properties`；没有该文件时 release 构建（assemble/bundle Release）直接失败，避免误传 debug 签名的包。仅本地测试可加 `-PallowDebugSigning`（`flutter build apk --release` 不能传 -P 时，用 `cd android && ./gradlew assembleRelease -PallowDebugSigning`）。
- `isMinifyEnabled = true`、`isShrinkResources = true`，keep 规则在 `android/app/proguard-rules.pro`（微信、支付宝、高德 3D 地图 / 定位 / 搜索、阿里云号码认证、fastjson2、RootBeer，按各 SDK 官方文档）。
- 权限：定位（含后台）、`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION`（geolocator 服务声明 `foregroundServiceType="location"`）、`POST_NOTIFICATIONS`、`CHANGE_NETWORK_STATE`（号码认证）。release 只允许 HTTPS，debug 允许明文。

```bash
flutter build appbundle --release --dart-define-from-file=config/prod.json
flutter build ipa --release --dart-define-from-file=config/prod.json
```

### iOS

- Bundle ID `com.loopland.app`，最低 iOS 15。Info.plist 中文用途说明：使用期间定位、始终定位、运动与健身、健康（读 / 写）；`UIBackgroundModes = location`。
- `Runner.entitlements`：Sign in with Apple、Associated Domains（`applinks:$(LOOPLAND_ASSOCIATED_DOMAIN)`）。
- 需在 Xcode 打开的 Capabilities：Sign in with Apple、In-App Purchase、Associated Domains、Background Modes（Location updates）。

### 上线前检查清单

- [ ] `config/prod.json` 所有 `<...>` 占位符已替换；`LOOPLAND_ENV=prod`；`API_BASE` 为 HTTPS。
- [ ] 用 `LOOPLAND_ENV=dev` 打一个同配置的包，打开「环境检查」确认各 SDK 显示「已配置」，服务端 features 与预期一致。
- [ ] `android/key.properties`、release keystore 已就位并备份；`android/loopland.properties` 有高德 Key。
- [ ] 用 **release 签名** 的 MD5 / SHA1 更新：微信开放平台、支付宝、高德（发布版安全码）、号码认证 Android 方案。
- [ ] `ios/Flutter/Loopland.xcconfig` 已填；`apple-app-site-association` 已部署在 `LOOPLAND_ASSOCIATED_DOMAIN`，微信开放平台 Universal Link 与 `WECHAT_UNIVERSAL_LINK` 一致。
- [ ] Xcode Capabilities 已开启；App Store Connect 订阅商品与服务端 `apple_product_id` 一致；Server Notifications V2 已配置。
- [ ] 真机验证：一键登录（移动 / 联通 / 电信各一张卡，及 Wi‑Fi only 回退短信）、微信登录与支付（含未安装微信）、支付宝支付（含取消）、Apple 内购（沙盒）与恢复购买、人机验证、高德地图与暗色样式、锁屏后台定位。
- [ ] 首次安装：同意隐私弹窗前抓包 / 查日志，确认没有 SDK 初始化与定位请求（应用市场隐私合规检测）。
- [ ] release 包（R8 混淆后）完整跑一遍以上流程。
- [ ] 用户协议、隐私政策链接可访问，隐私政策中列出了上述第三方 SDK。

## 模拟 / 未完成 / 已知限制

- 未配置高德 Key（以及测试、Web、隐私弹窗同意前）时用备用地图：深色风格化街道 + 领地多边形 + 轨迹，可拖动、双指缩放、点选。
- 所有 SDK 都只在本环境用假实现做了单元测试，**需要真机＋真实 Key 验证**。
- `ali_auth` 的 iOS 插件在注册时会请求一次 `https://www.baidu.com/`（用于触发系统联网授权弹窗），发生在隐私弹窗之前；不带任何个人信息，但如需完全杜绝需 fork 插件去掉 `httpAuthority`。
- `ali_auth` 授权页的部分样式（如勾选框图片、Android 端某些字段）由 SDK 决定，按插件支持程度定制。
- `safe_device` 依赖 `play-services-location`（未调用其定位相关能力）。
- 支付宝 iOS 官方建议的 `NSAllowsArbitraryLoads` 未开启（审核风险），如遇支付宝 H5 收银台加载问题再按需加。
- 怪兽、宝箱、动态、组局、赛事、场馆、AI 等 V2 功能只有占位。
- 语音播报、手表心率 / 步频未接（上传字段已支持 `hr` / `cad` / `wearable`）。
