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

## dart-define

| 变量 | 说明 | 默认 |
| --- | --- | --- |
| `API_BASE` | 后端地址 | Android 模拟器 `http://10.0.2.2:8080`，其他 `http://localhost:8080` |
| `LOOPLAND_ENV` | `dev` 时：显示「验证码 000000」提示、支付多一个 `mock` 渠道（调 `POST /v1/dev/orders/{no}/pay`）、一键登录 / 微信 / Apple 在未接 SDK 时使用开发后端的 `dev:` 凭证 | `prod` |
| `AMAP_ANDROID_KEY` / `AMAP_IOS_KEY` | 高德地图 Key。当前平台没有 Key 时使用纯 Flutter 绘制的备用地图 | 空 |
| `WECHAT_APP_ID` / `WECHAT_UNIVERSAL_LINK` | 微信登录与支付（fluwx） | 空 |
| `ALIPAY_APP_ID` | 预留 | 空 |

## 目录

```
lib/
  api/        接口模型（手写 fromJson，容错）、dio 客户端（Bearer、X-Platform、refresh token 单飞轮换）、错误码中文文案
  auth/       token 存储（flutter_secure_storage）、登录状态、一键登录 MethodChannel、微信、Apple
  claim/      geo.go / claim.go 的 Dart 移植（圈地预览、「还差 X 米可闭合」），WGS-84→GCJ-02
  run/        定位源（geolocator）、运动记录状态机、离线存储与重传
  map/        TerritoryMapView 抽象：高德实现 + 备用 CustomPainter 实现
  pay/        微信 / 支付宝 / Apple 内购 / mock，下单后轮询订单
  features/   各页面
test/         claim 测试（Go 测试原样移植）、接口 JSON 解析（契约示例）、客户端、运动记录、组件测试
screenshots/  组件测试生成的界面截图
```

## 已实现

- 登录注册：视频背景登录页、本机号码一键登录（MethodChannel）、短信验证码、微信、Apple；协议勾选；`need_bind_phone` → 绑定手机号；隐私授权页（隐私政策 + 位置/行踪轨迹 + 运动健康数据分开授权），第一次户外运动前强制检查位置授权；注销冷静期账号登录后提示「账号注销中」并可撤回。
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

## 原生配置 TODO

### 高德地图
- 申请 Android / iOS Key，构建时传 `--dart-define=AMAP_ANDROID_KEY=... --dart-define=AMAP_IOS_KEY=...`（也可写入 `AndroidManifest.xml` 的 `com.amap.api.v2.apikey`）。
- 地图插件用的是 `amap_map 1.0.15`（官方 `amap_flutter_map` 的维护分支）。用户同意隐私政策后会调用 `AMapInitializer.updatePrivacyAgree`（高德合规要求，否则白屏）。
- 暗色自定义样式：在高德控制台导出 style 文件后接到 `AmapTerritoryMap` 的 `customStyleOptions`，目前用内置 `MapType.night`。
- iOS 需要 `pod install`；Android release 包需要按高德文档添加 ProGuard 规则。

### 定位（已写入工程）
- Android：`ACCESS_FINE/COARSE/BACKGROUND_LOCATION`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_LOCATION`、`POST_NOTIFICATIONS`、`WAKE_LOCK`。geolocator 的前台服务会显示「圈圈正在记录你的运动」常驻通知。国产 ROM 需要引导用户加入电池优化白名单（权限弹窗里有提示）。
- iOS：`NSLocationWhenInUseUsageDescription`、`NSLocationAlwaysAndWhenInUseUsageDescription`、`NSMotionUsageDescription`、`UIBackgroundModes = location`。Xcode 里在 Signing & Capabilities 打开 Background Modes → Location updates。

### 微信（fluwx）
- 开放平台申请移动应用，传 `WECHAT_APP_ID`。
- iOS：配置 Universal Link（Associated Domains `applinks:你的域名`，`apple-app-site-association`），传 `WECHAT_UNIVERSAL_LINK`；`Info.plist` 里把 `wxYOUR_WECHAT_APPID` 换成真实 URL Scheme。
- Android：签名 MD5 要和开放平台登记的一致。

### 支付宝（tobias）
- iOS：URL Scheme `looplandalipay` 已加，按 tobias 文档在 `pubspec.yaml` 配置 `tobias: url_scheme`。

### Apple
- Sign in with Apple：Xcode 打开 Sign in with Apple capability。
- 内购：打开 In-App Purchase capability；App Store Connect 建立与 `apple_product_id` 一致的自动续期订阅。下单返回的 `app_account_token` 作为 `applicationUserName`（StoreKit 2 的 appAccountToken）传给内购，成交后把 JWS 发到 `POST /v1/iap/apple`。启动时会监听 StoreKit 交易，补验证续费 / 中断的购买。

### 运营商一键登录（阿里云号码认证）
- 没有官方 Flutter 插件。Dart 侧通过 `MethodChannel('loopland/oneclick')` 调 `isAvailable` / `getToken`，原生侧在 `MainActivity.kt` 与 `AppDelegate.swift` 里是 TODO 桩（返回不可用），接入 SDK 后实现这两个方法即可。未接入时一键登录会提示改用验证码；开发环境返回 `dev:13800138000`。

### 其他
- 人机验证：`/v1/auth/sms/send` 的 `captcha_token` 尚未接（TODO 标在 `phone_code_form.dart`）。
- 设备风控：`rooted`、`multi_open` 需要原生检测，目前上报 `false`；`emulator` 由 device_info_plus 判断。
- 应用 ID：Android `com.loopland.loopland`，iOS bundle id 同名，上架前按需修改。

## 模拟 / 未完成

- 未配置高德 Key（以及测试、Web）时用备用地图：深色风格化街道 + 领地多边形 + 轨迹，可拖动、双指缩放、点选。
- 一键登录原生 SDK 未接；微信 / 支付宝 / Apple 需按上面配置后真机验证。
- 怪兽、宝箱、动态、组局、赛事、场馆、AI 等 V2 功能只有占位。
- 语音播报、手表心率 / 步频未接（上传字段已支持 `hr` / `cad` / `wearable`）。
