# 圈圈 Loopland · App（V1 + V2 第一批「玩法深化」）

Flutter 3 + Riverpod 客户端。接口约定以 `docs/api/v1.md` 和 `docs/api/v2-1-玩法.md` 为准。V2 第一批（城市怪兽、能量宝箱、守地挑战、赛季、城区联赛、限时活动、城市定向、伙伴养成、跑团接力、WebSocket 实时推送）已实现；其余 V2 入口（场馆、组局、动态、本地生活、能量商城、AI 剧情夜跑、轨迹绘画）显示「即将开放」。

## 环境

- Flutter 3.50.x stable（Dart 3.14）。依赖版本全部锁定在 `pubspec.yaml`。
- 注意：Flutter 3.47 起 `package:flutter/material.dart` 已废弃，本项目统一使用 `package:material_ui/material_ui.dart`。

```bash
cd app
flutter pub get
flutter analyze          # 应为 No issues found
flutter test             # 单元测试 + 组件测试
LOOPLAND_SCREENSHOTS=1 flutter test test/widgets   # 顺便把截图写到 screenshots/（V2 页面在 screenshots/v2/）
# 联调：后端以 LOOPLAND_ENV=dev 运行（V2 测试还需要管理员 admin:admin-password-1 来投放怪兽 / 宝箱）
LOOPLAND_LIVE_API=http://localhost:8082 flutter test integration_live
# AI（ai_live_test.dart）：开发环境没配 AI 时后端用内置模拟 AI，含真实 SSE 流式
```

## 配置（config/app.yaml）

前端所有的域名 / 端口 / API 地址 / 协议链接 / SDK Key 都在**一个文件**：`config/app.yaml`（已提交，**不含任何真实密钥**，按 `dev` / `prod` 分档）。真实 Key、你电脑的局域网 IP 写在 `config/app.local.yaml`（已 gitignore，结构相同，深度合并覆盖 app.yaml）。生成器把它们转成各端真正读取的文件：

```bash
dart run tool/gen_config.dart --profile dev        # 生成下面三个文件（都已 gitignore，勿手改）
flutter run --dart-define-from-file=config/dev.json
```

| 生成文件 | 谁读 | 内容 |
| --- | --- | --- |
| `config/<profile>.json` | `flutter run/build --dart-define-from-file=` | 所有 Dart 侧配置（下表 dart-define） |
| `android/loopland.properties` | `android/app/build.gradle.kts` | `AMAP_ANDROID_KEY`（manifestPlaceholders → `com.amap.api.v2.apikey`）、`KEY_PROPERTIES`、`LOOPLAND_PROFILE` |
| `ios/Flutter/Loopland.xcconfig` | `Debug.xcconfig` / `Release.xcconfig`（在 `LooplandDefaults.xcconfig` 之后 include） | `WECHAT_APP_ID`、`ALIPAY_URL_SCHEME`、`LOOPLAND_ASSOCIATED_DOMAIN`、可选 `DEVELOPMENT_TEAM` |

每个生成文件开头都有「生成文件，勿手改，来源 config/app.yaml」（JSON 没有注释，写在 `_generated` 键里，Flutter 会把它当作一个没人读的 dart-define）。原生两个文件只对应**最近一次生成的 profile**，切换 dev / prod 时重新运行生成器（Gradle 发现 profile 不一致会打印警告）。

唯一单独存放的密钥文件是 release 签名 `android/key.properties`（模板 `android/key.properties.example`，`storeFile` 相对 `android/`）。它的路径可在 app.yaml 的 `android.key_properties` 改（例如 CI 的密钥目录），**密码不要写进 app.yaml**。

### 配置项

| app.yaml 键 | dart-define / 原生变量 | 说明 |
| --- | --- | --- |
| `env` | `LOOPLAND_ENV` | `dev`：验证码 000000 提示、`mock` 支付、「环境检查」页；未配置 SDK 时一键登录 / 微信用开发后端的 `dev:` 凭证。`prod`：正式 |
| `api.base_url` | `API_BASE` | 后端 REST 地址 `scheme://host:port`。Android 模拟器 `http://10.0.2.2:8080`，iOS 模拟器 / Chrome `http://localhost:8080`，真机用电脑局域网 IP（release 包只允许 HTTPS） |
| `api.ws_url` | `WS_URL` | 可选，完整 WebSocket 端点。**留空**时 App 运行时由 `API_BASE` 推导（http→ws、https→wss，同 host / 端口，加 `/v1/ws`），所以单独覆盖 `API_BASE` 时 WebSocket 跟着变 |
| `links.user_agreement` / `links.privacy_policy` | `USER_AGREEMENT_URL` / `PRIVACY_POLICY_URL` | 用户协议 / 隐私政策（启动隐私弹窗、登录页、一键登录授权页、设置页） |
| `links.universal_link_domain` | `LOOPLAND_ASSOCIATED_DOMAIN`（xcconfig） | Universal Link 域名，只写域名；Associated Domains = `applinks:<域名>` |
| `wechat.app_id` / `wechat.universal_link` | `WECHAT_APP_ID`（Dart + xcconfig）/ `WECHAT_UNIVERSAL_LINK` | 微信开放平台 AppID；iOS Universal Link（`https://<universal_link_domain>/路径/`） |
| `alipay.app_id` / `alipay.universal_link` | `ALIPAY_APP_ID` / `ALIPAY_UNIVERSAL_LINK` | 可选（风控优化 / iOS Universal Link）。支付只用服务端返回的 `order_string` |
| `alipay.url_scheme` | `ALIPAY_URL_SCHEME`（xcconfig） | iOS 支付宝回调 scheme，默认 `loopland-alipay`，不能含下划线 |
| `amap.android_key` / `amap.ios_key` | `AMAP_ANDROID_KEY`（Dart + Manifest）/ `AMAP_IOS_KEY` | 高德 Key。没有 Key 时使用纯 Flutter 备用地图 |
| `amap.style_data` / `amap.style_extra_data` | `AMAP_STYLE_DATA` / `AMAP_STYLE_EXTRA_DATA` | 高德暗色自定义样式 asset 路径（如 `assets/map/style.data`），可选 |
| `amap.navigation_url` | `AMAP_NAVIGATION_URL` | 高德 URI API（领地弹层「高德导航」），默认 `https://uri.amap.com/navigation` |
| `aliyun.auth_secret_android` / `_ios` | `ALIYUN_AUTH_SECRET_ANDROID` / `_IOS` | 阿里云号码认证「方案秘钥」，两个平台各一个 |
| `aliyun.captcha_prefix` / `captcha_scene_id` | `ALIYUN_CAPTCHA_PREFIX` / `_SCENE_ID` | 阿里云验证码 2.0 身份标与场景 ID；不配置时（开发）跳过人机验证 |
| `aliyun.captcha_js_url` / `captcha_page_url` | `ALIYUN_CAPTCHA_JS_URL` / `_PAGE_URL` | 验证码 Web SDK 地址；WebView 页面的 origin（场景开了域名白名单时改成白名单域名） |
| `ios.development_team` | `DEVELOPMENT_TEAM`（xcconfig） | 可选，Apple 签名团队 ID |
| `android.key_properties` | `KEY_PROPERTIES`（loopland.properties） | release 签名配置文件路径，默认 `key.properties` |
| `allow_empty` | — | prod 里允许留空的 SDK Key 列表，如 `[aliyun.captcha_prefix, aliyun.captcha_scene_id]` |

另有 `LOOPLAND_CONFIG_PROFILE`（生成器写入的 profile 名，「环境检查」页显示「配置来源」）。`shared:` 下是所有 profile 共用的默认值。值里的 `<...>` 占位符按「未配置」处理。

### 生成器 `tool/gen_config.dart`

```
dart run tool/gen_config.dart [--profile dev] [--api-base URL] [--set 键=值 ...]
                              [--config 文件] [--local 文件 | --no-local] [--out-dir 目录]
                              [--allow-empty-keys] [--check] [--help]
```

- 校验（出错时打印中文原因、**不写任何文件**、退出码 1）：必填项；URL 格式；未知的键（防拼写错误，会列出可用的键）；Universal Link 必须 https、以 `/` 结尾且在 `links.universal_link_domain` 下；URL Scheme 不能含下划线；微信 AppID 以 `wx` 开头；asset 路径用 `/`。`env: prod` 时还要求：全部 https / wss、不能是 localhost / 10.0.2.2 / 局域网 IP、SDK Key 不能为空（除非列进 `allow_empty` 或加 `--allow-empty-keys`，后者只用于冒烟构建）。
- `--check` 只校验；`--out-dir` 把三个文件写到别的根目录（其下 `config/`、`android/`、`ios/Flutter/`）；内容没变的文件不会被重写（不触发 Gradle / Xcode 重新构建）。
- Linux / macOS / Windows 行为一致：路径用 `package:path` 拼接，输出统一 UTF-8（无 BOM）+ `\n` 换行；输入接受 BOM 和 CRLF。从任意目录运行都以 `app/` 为根。
- 逻辑在 `tool/src/app_config.dart`，单元测试 `test/tool/gen_config_test.dart`（`flutter test` 一起跑）。

### 优先级（低 → 高）

1. `config/app.yaml` 的 `shared`
2. `config/app.yaml` 的 `profiles.<profile>`
3. `config/app.local.yaml` 的 `shared`
4. `config/app.local.yaml` 的 `profiles.<profile>`
5. 生成器 `--set 键=值`（可重复，CI 用它从环境变量注入密钥）
6. 生成器 `--api-base`
7. `flutter run/build` 命令行上单独写的 `--dart-define=键=值`：实测（Flutter 3.50）会覆盖 `--dart-define-from-file` 里的同名值——flutter_tools 先放文件里的值、再追加命令行的值，后者生效。Android 的 `build.gradle.kts` 同样以 dart-define 为准，没有时才用 `android/loopland.properties`。iOS 原生变量（xcconfig）不受 `--dart-define` 影响，只能重新生成。

**没运行生成器也能跑**：不带 `--dart-define-from-file` 时 App 使用内置兜底值（`lib/core/config_keys.dart` 的 `ConfigFallbacks`，与 app.yaml 的默认值一致，测试会检查）：API 在 Android 上 `http://10.0.2.2:8080`、其他平台 `http://localhost:8080`，`env` 为 `prod`，所有 SDK 未配置；启动日志（`loopland.config`）会提示先运行生成器。iOS / Android 原生变量用 `LooplandDefaults.xcconfig` / 空的高德 Key。要 dev 功能（验证码提示、mock 支付、`dev:` 登录）请按下面的方式运行。

### 运行（开发后端 `LOOPLAND_ENV=dev`）

`scripts/dev.sh app [设备]` / `.\scripts\dev.ps1 app [设备]` 会自动 `pub get`、生成配置并 `flutter run`（`emulator-*` 设备且没有 app.local.yaml 时自动用 `10.0.2.2`）。手动运行：

| 目标 | Linux / macOS（bash） | Windows（PowerShell） |
| --- | --- | --- |
| Android 模拟器 | `dart run tool/gen_config.dart --profile dev --api-base http://10.0.2.2:8080`<br>`flutter run -d emulator-5554 --dart-define-from-file=config/dev.json` | `dart run tool/gen_config.dart --profile dev --api-base http://10.0.2.2:8080`<br>`flutter run -d emulator-5554 --dart-define-from-file=config/dev.json` |
| iOS 模拟器（仅 macOS） | `dart run tool/gen_config.dart --profile dev`<br>`flutter run -d "iPhone 16" --dart-define-from-file=config/dev.json` | — |
| 真机（Android / iPhone，同一 Wi-Fi） | 在 `config/app.local.yaml` 写 `profiles: { dev: { api: { base_url: http://192.168.1.10:8080 } } }`（电脑局域网 IP，`ip addr` 查），然后<br>`dart run tool/gen_config.dart --profile dev`<br>`flutter run -d <设备ID> --dart-define-from-file=config/dev.json` | 同左（局域网 IP 用 `ipconfig` 查），<br>`dart run tool/gen_config.dart --profile dev`<br>`flutter run -d <设备ID> --dart-define-from-file=config/dev.json` |
| Chrome | `dart run tool/gen_config.dart --profile dev`<br>`flutter run -d chrome --dart-define-from-file=config/dev.json` | 同左 |
| 临时换后端（不改文件） | `flutter run --dart-define-from-file=config/dev.json --dart-define=API_BASE=http://192.168.1.10:8080` | `flutter run --dart-define-from-file=config/dev.json "--dart-define=API_BASE=http://192.168.1.10:8080"` |

PowerShell 里 `--set` / `--dart-define` 的值含 `=`、空格或 `,` 时整个参数加引号，如 `dart run tool/gen_config.dart --profile prod "--set=wechat.app_id=$env:WECHAT_APP_ID"`。`flutter devices` 查设备 ID。真机访问电脑的后端还要放行防火墙端口 8080。

正式包（真实值放 `app.local.yaml`，或 CI 用 `--set`）：

```bash
dart run tool/gen_config.dart --profile prod
flutter build appbundle --release --dart-define-from-file=config/prod.json
flutter build ipa --release --dart-define-from-file=config/prod.json
# CI 示例：密钥来自环境变量
dart run tool/gen_config.dart --profile prod --set "amap.android_key=$AMAP_ANDROID_KEY" --set "wechat.app_id=$WECHAT_APP_ID"
```

```powershell
dart run tool/gen_config.dart --profile prod
flutter build appbundle --release --dart-define-from-file=config/prod.json
dart run tool/gen_config.dart --profile prod "--set=amap.android_key=$env:AMAP_ANDROID_KEY"
```

### 配置校验与服务端开关

- 启动时 `SdkConfig.logMissing()` 记录缺少的 Key（日志名 `loopland.config`），**release 包隐藏**缺 Key 的登录 / 支付入口而不是崩溃；debug 包仍显示入口，点了给出明确提示。
- 登录方式、支付渠道还要与服务端 `GET /v1/config/features` 取交集（会话内缓存）；请求失败时只显示短信登录，下次打开登录页重试。`captcha=true` 时发短信前显示人机验证。
- 开发环境（`LOOPLAND_ENV=dev`）登录页右上角和「设置」里有「环境检查」页：配置来源（app.yaml 的哪个 profile）、API / WebSocket 地址、各 SDK 是否配置、服务端 features、最终显示哪些入口、设备风控检测结果。

## 目录

```
config/app.yaml  全部配置的唯一来源（app.local.yaml 本机覆盖；dev.json / prod.json 为生成文件）
tool/gen_config.dart  配置生成器（逻辑在 tool/src/app_config.dart）
lib/
  api/        接口模型（手写 fromJson，容错）、dio 客户端（Bearer、X-Platform、refresh token 单飞轮换）、错误码中文文案
  auth/       token 存储（flutter_secure_storage）、登录状态、一键登录（ali_auth）、人机验证（WebView）、微信、Apple
  core/       Env / SdkConfig（所有配置，键名与兜底值在 config_keys.dart）、/v1/config/features、启动隐私弹窗、SDK 延迟初始化、主题
  features/debug/  环境检查页（仅 dev）
  claim/      geo.go / claim.go 的 Dart 移植（圈地预览、「还差 X 米可闭合」），WGS-84→GCJ-02
  run/        定位源（geolocator）、运动记录状态机、离线存储与重传
  map/        TerritoryMapView 抽象：高德实现 + 备用 CustomPainter 实现（V2：怪兽范围圈 + 徽章、宝箱、定向打卡点、路线虚线）
  realtime/   WebSocket 客户端（重连 / 重订阅 / 鉴权失败刷新 token / 心跳看门狗）、Riverpod providers、站内横幅
  pay/        微信 / 支付宝 / Apple 内购 / mock，下单后轮询订单
  features/   各页面（V2 玩法在 features/play/：怪兽、宝箱、玩法中心、赛季、联赛、定向、活动、伙伴、接力、守地）
test/         tool/ 配置生成器测试；claim 测试（Go 测试原样移植）、接口 JSON 解析（契约示例）、客户端、运动记录、组件测试
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
- **V2 · 玩法深化**（`docs/api/v2-1-玩法.md`）：
  - 地图：按视野与领地一起（同一防抖）加载 `GET /v1/map/objects`，画怪兽范围圈 + 怪兽徽章（剩余血量 %）、金色宝箱、定向「下一站」打卡点；高德用多边形近似圆 + Marker（徽章位图由同一套 Canvas 画法渲染），备用地图直接绘制并做点击命中。点怪兽 → 怪兽页，点宝箱 → 宝箱弹层（用当前 GCJ-02 位置开箱，处理 `out_of_range` / `already_opened` / `chest_expired`），点打卡点 → 路线页。右上「S3 剩 N 天」→ 赛季页，右侧「玩法」→ 玩法中心。
  - 怪兽来袭页（`/bosses/:id`）：倒计时、怪兽插画（沙发怪 / 熬夜蝠 / 雾霾怪 / 糖分怪；卡牌 SVG + `widgets/monster_art.dart` 的矢量画法）、等级、描述、霸占领地、血量条（WebSocket 实时）、伤害规则（相同规则合并为「跑步 / 骑行」）、「去运动出战」（范围内先 `engage`，再去开始页）、「发起合击」（带定位；显示伤害、合击加成、剩余能量、冷却倒计时，429 用 `retry_after_s`）、伤害榜、掉落概率公示（含「不支持付费抽取」）、击退 / 到期结果与 `my_rewards`（重复折算能量）。
  - 实时：登录（且已绑手机、已授权）后连 `/v1/ws?token=`；断线按 1/2/4/8/16/30 s 退避重连并重发订阅；握手失败或鉴权类关闭码时调用一次需要登录的接口，让 ApiClient 用 refresh token 轮换（失败则退出登录、停止重连）；75 s 收不到任何消息（服务端 30 s 一次 ping）视为断线。`territory_attacked` / `rally` 在顶部弹横幅，点击进领地 / 怪兽页。
  - 玩法中心（`/games`）：核心卡（城市争霸）+ 城区联赛、能量宝箱、城市定向、跑步伙伴（内嵌喂食卡）、跑团接力、限时活动（进行中数量）；AI 剧情夜跑、轨迹绘画「即将开放」。点选玩法切换上方大卡（同原型）。
  - 赛季页（`/season`）：段位卡（进度条、段位条、「距 黄金 I 还差 x km²」）、我的排名 / 跑团排名、赛事中心（→ 城区联赛 `/league`）、本地生活 / 能量商城（即将开放）、奖牌（带进度环）/ 赛季任务 / 排行（个人、跑团）。
  - 城市定向（`/routes`、`/routes/:id`）：路线列表与详情，地图上有序打卡点（已打卡 / 下一站 / 待打卡）+ 路线虚线，「去打卡」开始跑步。限时活动（`/campaigns`）：规则中文化（距离、配速、开跑时段）、时间、奖励、完成状态。
  - 图鉴：怪兽页签（出手、击退、最佳排名，未遇到为剪影）；伙伴显示等级、经验条、陪跑米数、「喂 50 能量」。
  - 跑团接力：跑团页 / 社区页的接力卡（各棒由谁跑、距离、截止倒计时）；团长可发起（棒数、每棒距离）。
  - 运动中：每移动 400 m 或 2 分钟加载附近玩法对象并画在地图上；进入怪兽范围提示「正在对沙发怪造成伤害」，经过宝箱 / 到达下一站也有提示。结算页新增：怪兽伤害、能量宝箱、守地成功、城市定向、限时活动、赛季任务、陪跑伙伴、跑团接力。
  - 守地挑战：领地弹层（自己的地）和建城页在有 `defense` 时显示截止倒计时「24 小时内跑一圈经过这里即可加固」。建筑选择：图鉴建筑 `blueprint: true` 时高于等级也显示「图纸可建」（最终以服务端 `level_too_low` 为准）。
- 社区（V2 第二批，接口 `docs/api/v2-2-社区.md`）：
  - 社区首页（底部「社区」）：我的跑团卡、动态 / 组局 / 赛事 / 消息入口（带未读数）、即将开始的集结跑、我报名的组局、进行中的赛事。
  - 动态（`/community/feed`）：关注 / 推荐；动态卡带图片九宫格和轨迹缩略图；详情（`/posts/:id`）两级评论、点赞、收藏、分享（微信 / 朋友圈 / 海报 / 链接）、举报；发布（`/posts/new`）最多 9 张图、附运动、可见范围、先过审核；结算页「一键带上战报发动态」。
  - 他人主页（`/users/:id`）：关注、私信、拉黑、关注 / 粉丝列表；我的页：关注 / 粉丝 / 获赞、编辑资料（`/me/profile`）、收藏、黑名单。
  - 轨迹回放（`/replays`）：上下滑，15–30 秒动画；会员「导出 1080p」暂显示即将上线。
  - 消息（`/inbox`）：互动 / 领地 / 怪兽 / 系统分类与未读数；私信和群聊（`/conversations`、`/chat/:id`、`/chat/direct/:userId`），实时收消息、已读回执、免打扰、陌生人限制提示。
  - 组局（`/meetups`）：附近（按距离）/ 我的，约跑 / 约球 / 约骑，地图选点创建，报名即进群聊。
  - 集结跑：跑团页里发起、报名、到场签到（离集合点 300 m 内），签到满 2 人有加成，结算页显示「集结跑加成」。
  - 赛事（`/races`）：线上赛 / 线下赛报名、排行榜、完赛奖牌（结算页「赛事完赛」）。
  - 跑团：邀请码（生成、分享、`/crews/join-code` 加入）、编辑跑团（名称、头像、城区、加入方式，先生效后审核）。
- **AI 助手 / 路线 / 战报（V2 第三批 E-08、A-04、C-04、C-05 / D-05，接口 `docs/api/v2-3-AI.md`）**：`GET /v1/config/features` 的 `ai=false`（或请求失败 / 旧后端没有该字段）时下面所有入口都隐藏。代码在 `lib/api/ai_api.dart`、`ai_models.dart`、`lib/features/ai/`。
  - AI 助手圈圈（`/ai`，设计稿 12_AI_助手）：入口在地图右侧「AI」、我的「AI 助手圈圈」、他人领地弹层和怪兽页的「问 AI」（`/ai?context=territory|boss&id=&name=`，预填问题并显示「关于领地「xx」」，只随下一条消息发送 `context`）。顶部公示模型名称 + 备案号（点开「关于 AI 助手」：免责声明、图片识别、额度、180 天保存说明）和本周剩余次数（会员显示「不限次数」）；开场白 + 快捷问题；历史倒序分页（`before=`，滚到顶加载更早的）；菜单「清空对话」。
  - 流式回答：`POST /v1/ai/chat` 带 `Accept: text/event-stream`，dio `ResponseType.stream` + 自写 SSE 解析（`parseSse`：`event:` / 多行 `data:` / 注释 / CRLF / 任意切块），`delta` 实时追加（等待首字时显示三点动画，生成中有光标），`card` 立即渲染，`done.message` 为准（输出被拦截时替换文字、去掉卡片），`event: error` 显示在回答气泡里并可重试；流在第一个事件前就失败（网络 / 代理）时自动改用 JSON 请求，后端直接回 JSON 也能处理。每条 AI 回答下方都有「内容由 AI 生成」。
  - 卡片：路线卡（缩略轨迹、距离 / 可圈面积 / 用时、理由、「一键开跑」→ 开跑页预选该路线并自动开始）、领地卡（→ 地图定位并高亮，`mapFocusProvider`）、怪兽卡（→ 怪兽页）。
  - 拍照 / 相册（`purpose=chat` 上传），`vision=false` 时不显示相机按钮，`ai_image_unsupported` 后也隐藏；`ai_quota_exceeded` 弹「开通会员」→ 会员页（之后本地记为用完，直接弹窗不再请求）；`content_blocked` / `rate_limited` 退回草稿；`ai_unavailable`（信息接口 503 或 `enabled=false`）整页提示不可用。
  - 开跑页「本次目标」：自由圈地之后是 `GET /v1/ai/routes` 的 AI 推荐闭环 / 夺回 xx / 守卫 xx / 顺路打怪兽（定位中 / 加载中 / 空 / 失败可重试 / 「刷新 AI 路线」），选中后展开距离·用时·面积、理由（`ai_generated` 时标「内容由 AI 生成」）、途经目标，闭环可选 3 / 5 / 10 km；预览地图画路线虚线和编号目标并自动取景。开跑时 `goal = {type: ai_route, route_id, route_type}`，运动页沿用城市定向的路线虚线层画引导线 + 编号目标，接近目标时提示（引导线不写入断点续跑快照）。
  - 结算页 AI 战报：结算后请求 `POST /v1/activities/{id}/ai-report`，柠檬绿卡片逐字打出、标「内容由 AI 生成 · 模型名」，「换一换 · 剩 N 次」（用完显示「已换完」，409 `regenerate_limit` 提示）；「一键带上战报发动态」把战报带进发布页，作为单独的「AI 战报」块（可移除，不计入 500 字），发布时 `ai_report: true`。发布页也可以对选中的运动「AI 写战报 / 换一篇」，换运动时自动移除。动态卡片和详情把 `post.ai_report` 显示为单独的「AI 战报」块并标注 AI 生成。
- **AI 跟练（V2 第三批 C-09，接口 `docs/api/v2-3-AI.md`「App · AI 跟练」）**：
  - 入口：开始页「居家跟练」→「AI 跟练」（`/coach?sport=`），原来的自由计时 / 计数保留为「手动记录」（`/train/:sport`）。课程列表按 跳绳 / HIIT / 普拉提 / 力量 分页签，来自 `GET /v1/ai/workouts`；接口 503 `ai_unavailable`、断网或返回空时用内置课程（`lib/coach/workout.dart` 的 `builtinWorkouts`，与服务端默认 `workouts` 一致）。姿态计次在端上完成、不调大模型，所以 `features.ai=false` 时也不隐藏。
  - 跟练页（`/coach/:key`，设计稿 11_AI_跟练）：前置摄像头预览 + 骨架叠加（CustomPainter）、「AI 自动计数」大数字、组数条、提示气泡、底部面板（已用时 / 倒计时或 次数/目标 / 组数 / 开始·暂停·继续 / 预计能量）；5 秒准备倒计时，按动作 `count`（到目标次数自动完成本组）或 `time` 计时，组间 / 动作间休息（显示「下一个」，可跳过），暂停 / 继续、完成本组、跳过动作、结束训练，结束后显示小结再「领取能量」。
  - 计次（`lib/coach/rep_counter.dart`，纯 Dart，`test/coach/` 用合成关键点序列测试，含抖动 / 丢帧 / 离群点 / 低帧率）：`jump` 用鼻、肩、髋、膝、踝相对各自偏移的截尾均值得到身体高度（按躯干长度归一化），对「峰值相对前一个谷底的升幅」做迟滞（≥ max(0.055 躯干长, 35% 近期幅度)，升幅须在 0.6 s 内完成，过滤慢晃和漂移）；`squat` 膝角（≥155° 站直 / ≤115° 蹲下）、`pushup` 肘角（≥150° / ≤100°）、`crunch` 躯干与地面夹角（≤15° / ≥28°），角度取 0.3 s 中位数，回到起始姿势才计 1 次；`none` 只计时。
  - 画面只在手机本地交给 ML Kit 识别，不上传、不保存（页面和课程列表都有说明，训练结束立即关闭摄像头，切到后台释放摄像头并暂停）。「全身入镜」提示；4 秒窗口内光线太暗 / 可用帧不足 40% / 2.5 秒没有画面时自动改为手动计数（+1 / +10 / −1），点状态条可恢复自动；没有摄像头权限、没有摄像头、Web / 桌面：计时 + 手动计数。
  - 语音（`flutter_tts`，zh-CN）：准备、每组开始、过半、最后 3 个、最后 3 秒倒数、休息与下一个动作、完成；右上角静音开关（记在本机；跑步页目前没有语音设置）。
  - 上传沿用 `POST /v1/activities`（跳绳 `amount` = 总次数，其余为分钟数）+ `coach`（`workout_key`、`camera`、`reps_detected`、`reps_manual`、`sets_done`），结果走原来的结算页（能量、复核）。手动补记比识别多 20% 以上时小结页提示可能进入人工复核（服务端规则 `coach_mismatch`）。
- **联名权益 / 卡券包 / 能量商城（V2 第四批 A-16、E-04、E-05，接口 `docs/api/v2-4-本地生活与商户.md`）**：代码在 `lib/api/perks_api.dart`、`perks_models.dart`、`lib/features/local/`（`campaigns_tab.dart`、`shop_tab.dart`、`coupons_pages.dart`、`supply_sheet.dart`）、`lib/widgets/cosmetics.dart`。
  - 本地生活「联名活动」：进行中的品牌联名（时间、门店数、权益、怎么领：补给站 / 商户宝箱 / 据点、规则、投放点，点投放点回到地图并居中）。「能量商城」：领地皮肤 / 头像框 / 地图标记按类型筛选、预览，兑换前确认（`not_enough_energy`、`already_owned`），装备 / 卸下（同类只装备一个）；明示「能量只能运动获得，不能充值、不能转让」，没有付费入口。
  - 卡券包 `/me/coupons`（我的、结算页、联名活动入口）：未使用 / 已使用 / 已过期；券详情 `/me/coupons/:id` 显示到店二维码（`qr_flutter` 本地绘制，`GET /v1/coupons/{id}/qr` 每 50 秒和回到前台时刷新，倒计时，截图无效）、券码、规则（含「核销需要当天有一条运动记录」）、有效期、来源。没有做屏幕调亮（不想为此引入原生插件）。
  - 地图：补给站图标 + 范围圈（今天领过变灰），点开「领取」（先定位判断范围，`too_far` / `already_claimed` / `sold_out`）；商户宝箱（`merchant` + `perk_title`）开出券；结算页「联名福利」列出本次得到的券。
  - 装扮：`UserBrief.avatar_frame` 由 `UserAvatar` 按 key 画框（服务端默认 `frame_gold` / `frame_runner` / `frame_night`，另有几种备用；未知 key 画通用框，尺寸不变）；领地 `skin` 的 fill / stroke / pattern（`grid`、`stripe(s)`、`wave(s)`、`dot(s)`、`hex`）在备用地图上完整绘制，高德只用颜色；`/v1/me` 的 `equipped.map_marker` 替换我的位置标记（高德作为定位图标）。
  - 联调：`LOOPLAND_LIVE_API=… LOOPLAND_LIVE_DB=<同一个库的 psql 连接串> flutter test integration_live/perks_live_test.dart`（`LOOPLAND_LIVE_DB` 用来给测试账号加能量；不设时只测能量不足）。
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
- 配置：`config/app.yaml`（真实值写 `app.local.yaml`）的 `aliyun.auth_secret_android` / `aliyun.auth_secret_ios`。
- 实现：`lib/auth/one_click.dart`。`initSdk(isDelay)` → 终端检查（600024）→ `login` 拉起授权页 → 600000 拿 token → `POST /v1/auth/login provider=oneclick`（绑定手机号时为 `oneclick_token`）。无 SIM、只开 Wi‑Fi、运营商维护、秘钥错误、超时等任何失败都提示原因并转到短信登录，不会崩溃。只有 `LOOPLAND_ENV=dev` 且未配置秘钥时才用 `dev:13800138000`。
- 授权页：全屏深色 `#0E0E10`、荧光绿 `#DCF26A` 登录按钮、Logo（`assets/brand/auth_logo.png`）、slogan、「其他手机号登录」、运营商协议＋《用户协议》《隐私政策》（URL 来自 `links.user_agreement` / `links.privacy_policy`），协议**不默认勾选**，未勾选点登录时弹二次确认。
- 合规：插件自带的 `READ_PHONE_STATE`、`WRITE_EXTERNAL_STORAGE` 已在 manifest 中 `tools:node="remove"`；插件开启的明文流量在 release 中关闭。
- iOS：插件 podspec 已加 `-ObjC`；**不要**再手动把 ATAuthSDK.framework 拖进工程。

### 2. 微信（登录 / 支付）— `fluwx 6.0.6`

- 申请：微信开放平台 → 移动应用（Android 包名＋签名 MD5；iOS Bundle ID＋Universal Link），开通「微信登录」，商户平台开通 APP 支付并关联 AppID。
- 配置：`config/app.yaml` 的 `wechat.app_id`、`wechat.universal_link`、`links.universal_link_domain`（生成器同时写进 dart-define 和 `ios/Flutter/Loopland.xcconfig`）；服务器 `https://<域名>/.well-known/apple-app-site-association` 中加入 `<TeamID>.com.loopland.app` 和对应路径。
- Android：fluwx 的 manifest 已用 activity-alias 声明 `com.loopland.app.wxapi.WXEntryActivity` / `WXPayEntryActivity`，并有 `<queries><package com.tencent.mm/>`，无需自写 Activity。
- iOS：Info.plist URL Type `weixin` = `$(WECHAT_APP_ID)`；`LSApplicationQueriesSchemes` 含 `weixin`、`weixinULAPI`、`weixinURLParamsAPI`；`Runner.entitlements` 的 Associated Domains = `applinks:$(LOOPLAND_ASSOCIATED_DOMAIN)`。
- 登录用 `snsapi_userinfo`；支付把服务端 `pay_params` 的 `appid / partnerid / prepayid / package / noncestr / timestamp / sign` 原样传给 SDK（缺字段直接报错，不下发）。未安装微信时提示「未安装微信…」，且**不会先创建订单**。

### 3. 支付宝 — `tobias 6.0.0`

- 申请：支付宝开放平台创建应用，开通「APP 支付」，填应用签名＋包名；密钥在服务端，App 只拿 `order_string`。
- iOS：Info.plist URL Type `alipay` = `$(ALIPAY_URL_SCHEME)`（app.yaml 的 `alipay.url_scheme`，默认 `loopland-alipay`，不能含下划线；tobias 按 URLName `alipay` 找它）；`LSApplicationQueriesSchemes` 含 `alipay`、`alipays`。（API 约定 iOS 只能用 Apple 内购，这里的配置是为以后 / 审核外渠道预留。）
- 支付后**无论 SDK 返回什么**都会轮询 `GET /v1/orders/{no}`：9000 / 8000 / 6004 等待回调直到 `paid`；6001 取消或失败时也再查几秒，服务端说已支付就算成功。

### 4. Apple（登录 / 内购）— `sign_in_with_apple`、`in_app_purchase 3.3.1`（`in_app_purchase_storekit 0.4.17`）

- Xcode → Runner → Signing & Capabilities：打开 **Sign in with Apple**、**In-App Purchase**、**Associated Domains**、**Background Modes → Location updates**（`Runner/Runner.entitlements` 已包含前两项的 entitlement；In‑App Purchase 没有 entitlement key，但要在 App ID 上开启）。
- App Store Connect：建立与 `apple_product_id` 一致的自动续期订阅；配置 App Store Server Notifications V2 指向 `POST /v1/pay/notify/apple`。
- 内购：`applicationUserName` = 下单返回的 `app_account_token`（StoreKit 2 `appAccountToken`）。storekit 插件 0.4.x 默认 StoreKit 2，`serverVerificationData` 就是交易的 **`jwsRepresentation`**，发到 `POST /v1/iap/apple`；**服务端返回 200 后才 `finishTransaction`**，校验失败不 finish（StoreKit 下次启动重发）。拿到的不是 JWS（旧版收据）时不发送并提示。最低系统 iOS 15（StoreKit 2）。
- 会员页有「恢复购买」按钮（`restorePurchases` → 逐笔 JWS 验证）。

### 5. 高德地图 — `amap_map 1.0.15`

- 申请：高德开放平台 → 应用管理，分别添加 Android Key（包名＋发布版 / 调试版 SHA1）和 iOS Key（Bundle ID）。
- 配置：`config/app.yaml` 的 `amap.android_key` / `amap.ios_key`。Android Key 经 dart-define（或生成的 `android/loopland.properties`）→ manifestPlaceholders → `com.amap.api.v2.apikey`；Dart 的 `AMAP_ANDROID_KEY` / `AMAP_IOS_KEY` 通过插件 `AMapInitializer.init(apiKey:)` 传给 SDK（iOS 只走这一路）。
- 隐私合规：只有用户同意启动隐私弹窗后才调用 `AMapInitializer.updatePrivacyAgree`（插件在创建地图时转成 SDK 的 `updatePrivacyShow/updatePrivacyAgree`），之前一律显示备用地图；geolocator 同样在同意前不启动，户外运动前还要求「位置信息与行踪轨迹」授权。
- 暗色样式：高德控制台「自定义地图」发布后下载 `style.data` / `style_extra.data`，放进 `assets/map/`，在 `config/app.yaml` 设 `amap.style_data: assets/map/style.data`、`amap.style_extra_data: assets/map/style_extra.data`，地图自动启用 `customStyleOptions`；否则用内置 `MapType.night`。
- iOS 需要 `pod install`。

### 6. 阿里云验证码 2.0（人机验证）— `webview_flutter`

- 申请：阿里云验证码 2.0 控制台 → 新建场景（**V3 架构**，即验证参数随业务请求一起提交、由服务端 VerifyIntelligentCaptcha 校验），拿到**身份标 prefix** 和**场景 ID**。服务端配置同一场景的 AccessKey。
- 配置：`aliyun.captcha_prefix`、`aliyun.captcha_scene_id`（SDK 地址 `aliyun.captcha_js_url`、页面 origin `aliyun.captcha_page_url`）。
- 实现：`lib/auth/captcha.dart` 在 WebView 里加载 `AliyunCaptcha.js`（`AliyunCaptchaConfig = {region: "cn", prefix}`，`initAliyunCaptcha({SceneId, mode: "embed", success})`），`success(captchaVerifyParam)` 经 JS Channel 回传，作为 `captcha_token` 调 `POST /v1/auth/sms/send`。服务端 `features.captcha=false` 时跳过；为 true 但 App 未配置时提示「人机验证未配置」，不发请求。`captcha_failed` 有中文提示。

### 7. 设备风控 — `safe_device 1.4.1`

`device.rooted`（Android RootBeer / iOS DTTJailbreakDetection）、`device.emulator`（device_info_plus ＋ safe_device）、`device.multi_open`（应用私有目录不是 `/data/user/0/com.loopland.app`：MIUI/ColorOS 双开 999、三星 95、VirtualApp/平行空间等容器）。safe_device 的模拟定位检测已关闭（会触发定位）；模拟定位由 geolocator 的 `isMocked` 逐点上报。多开是启发式判断，工作资料（work profile）也会被标记，服务端只作为风险信号使用。

### 8. AI 跟练 — `camera 0.12.2`、`google_mlkit_pose_detection 0.16.1`、`flutter_tts 4.2.5`

- ML Kit 姿态识别模型随包内置（不依赖 Google Play 服务、不联网下载），stream 模式、base 模型；处理不过来的帧直接丢弃。Android 用 NV21（个别机型给 3 平面 YUV 时在 Dart 里转），iOS 用 BGRA。
- Android：`CAMERA` 权限，`android.hardware.camera(.front)` 为 `required=false`；camera 插件自带的 `RECORD_AUDIO` 已 `tools:node="remove"`（不录音）。
- iOS：`NSCameraUsageDescription` 已写明 AI 跟练用途和「只在本地识别」；ML Kit 9 要求 **iOS 15.5**，工程最低版本已改为 15.5。0.16.1 是 CocoaPods 插件（1.0.x 改成了 SPM，1.0.1 的 SPM 清单还缺 FlutterFramework 依赖，1.0.2 才修，发布不足两周），工程其余插件走 SPM，首次 `flutter build ios` 会为它生成 Podfile 并 `pod install`。
- 依赖锁定在 `pubspec.lock`（`camera_android_camerax 0.7.6`、`camera_platform_interface 2.15.0` 取发布两周以上的版本）。

### Android release 构建

- `signingConfigs.release` 读 `android/key.properties`（路径可由 app.yaml 的 `android.key_properties` 改）；没有该文件时 release 构建（assemble/bundle Release）直接失败，避免误传 debug 签名的包。仅本地测试可加 `-PallowDebugSigning`（`flutter build apk --release` 不能传 -P 时，用 `cd android && ./gradlew assembleRelease -PallowDebugSigning`）。
- `isMinifyEnabled = true`、`isShrinkResources = true`，keep 规则在 `android/app/proguard-rules.pro`（微信、支付宝、高德 3D 地图 / 定位 / 搜索、阿里云号码认证、fastjson2、RootBeer，按各 SDK 官方文档）。
- 权限：定位（含后台）、`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_LOCATION`（geolocator 服务声明 `foregroundServiceType="location"`）、`POST_NOTIFICATIONS`、`CHANGE_NETWORK_STATE`（号码认证）。release 只允许 HTTPS，debug 允许明文。

```bash
dart run tool/gen_config.dart --profile prod
flutter build appbundle --release --dart-define-from-file=config/prod.json
flutter build ipa --release --dart-define-from-file=config/prod.json
```

### iOS

- Bundle ID `com.loopland.app`，最低 iOS 15.5（ML Kit）。Info.plist 中文用途说明：使用期间定位、始终定位、运动与健身、健康（读 / 写）、相机（发动态 / 头像 / AI 跟练）；`UIBackgroundModes = location`。
- `Runner.entitlements`：Sign in with Apple、Associated Domains（`applinks:$(LOOPLAND_ASSOCIATED_DOMAIN)`）。
- 需在 Xcode 打开的 Capabilities：Sign in with Apple、In-App Purchase、Associated Domains、Background Modes（Location updates）。

### 上线前检查清单

- [ ] `dart run tool/gen_config.dart --profile prod` 校验通过（无 `allow_empty` / `--allow-empty-keys`，无 example.com 占位域名警告）；`api.base_url` 为 HTTPS。
- [ ] 用 `LOOPLAND_ENV=dev` 打一个同配置的包，打开「环境检查」确认各 SDK 显示「已配置」，服务端 features 与预期一致。
- [ ] `android/key.properties`、release keystore 已就位并备份；生成的 `android/loopland.properties` 是 prod 的（有高德 Key）。
- [ ] 用 **release 签名** 的 MD5 / SHA1 更新：微信开放平台、支付宝、高德（发布版安全码）、号码认证 Android 方案。
- [ ] 生成的 `ios/Flutter/Loopland.xcconfig` 是 prod 的；`apple-app-site-association` 已部署在 `links.universal_link_domain`，微信开放平台 Universal Link 与 `wechat.universal_link` 一致。
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
- 动态、组局、场馆、本地生活、能量商城、AI 剧情夜跑、轨迹绘画等仍只有占位。
- 伙伴经验：`exp` 按服务端实现理解为累计经验，`exp_to_next` 为距下一级还差多少，本级进度 = `exp_per_level − exp_to_next`。
- WebSocket 只解析 `boss` / `territory_attacked` / `rally` / `ping`；客户端不回 pong（约定未要求）。实时横幅只在 App 前台时出现，系统推送未接。
- 跑步中的语音播报、手表心率 / 步频未接（上传字段已支持 `hr` / `cad` / `wearable`）；AI 跟练有语音。
- AI 跟练的计次阈值只用合成数据调过（`test/coach/`），需要真机实测：不同光线 / 距离 / 机位下的跳绳、开合跳、深蹲、俯卧撑、卷腹计数准确率，前置摄像头骨架叠加的镜像与对齐，低端机帧率，后台切换释放摄像头，TTS 中文语音（部分 Android 机没装中文 TTS 引擎时只显示文字）。
