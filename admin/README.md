# 圈圈 Loopland · 管理端（V1 + V2 第一批「玩法深化」+ 第二批「社区」+ 第三批「AI」）

运营后台。技术栈：Vite 6 + React 18 + TypeScript（strict）+ Ant Design 5 + react-router 6 + ECharts 5 + TanStack Query 5。
接口约定见 `../docs/api/v1.md`「管理端」一节、`../docs/api/v2-1-玩法.md`（「管理端」与玩法配置新增字段）、`../docs/api/v2-2-社区.md`（「管理端」）和 `../docs/api/v2-3-AI.md`（「内容审核升级」「管理端 · AI 用量」「玩法配置新增」），类型和请求函数手写在 `src/api/`。

## 运行

```bash
cd admin
pnpm install --frozen-lockfile

pnpm run dev            # 连真实后端：按 config.yaml 把 /admin/v1、/v1、/v1/ws 代理到 backend.url（默认 http://localhost:8080）
pnpm run dev:mock       # 假数据模式，不需要后端（--mode mock 叠加 config.mock.yaml）；账号 admin / xiaolin / amei / shop，密码任意（"wrong" 会失败）

pnpm run build          # 先 tsc --noEmit，再 vite build，产物在 dist/
pnpm run preview        # 本地预览 dist/（同样代理 API）
pnpm run lint           # eslint，0 warning
```

后端本地启动（见 `../server`）：`LOOPLAND_ENV=dev LOOPLAND_BOOTSTRAP_ADMIN='admin:admin-password-1' go run ./cmd/loopland-api`，然后用 admin / admin-password-1 登录。
`go run ./cmd/loopland-seed -api http://localhost:8080 -admin admin:admin-password-1` 会顺带造 V2 数据（赛季、活动、定向路线、怪兽、宝箱、跑团）。后台账号密码至少 10 位。

### 截图

```bash
pnpm run dev:mock          # 终端 1
pnpm run screenshots       # 终端 2；地址取自配置里的 dev_server（Vite 换了端口时加 BASE_URL=http://localhost:5174）
```

V2 页面另有一套：`pnpm run screenshots:v2`，存到 `screenshots/v2/`（会在内存假数据里召唤怪兽、撒宝箱、建活动；14_ 起是第二批「社区」：审核、举报、下架、敏感词、组局、赛事、审核员 / 运营视角，`ONLY=community` 只跑这部分；23_ 起是第三批「AI」：AI 审核判定与新处理动作、双阈值与预计人工量、AI 用量、查看用户 AI 对话、AI 大模型新字段、AI 跟练 / AI 配置、运营 / 审核员视角，`ONLY=ai` 只跑这部分；第四批「本地生活与商户」的商户 / 场馆 / 订场 / 核销结算 / 核销记录 / 核销台 / 总览待办 / 运营视角 / 窄屏商户对接在 `scripts/screenshots-v2-merchant.cjs`，`ONLY=merchant` 只跑这部分，编号从 `MERCHANT_FROM`（默认 39）起；核销台扫码用 Chromium 假摄像头播放现生成的券二维码视频，需要 ffmpeg）。连真实后端时加 `SHOT_DIR=real-v2 ADMIN_PASSWORD=admin-password-1 STAFF_PASSWORD=<xiaolin / amei 的密码>`（这两个账号需先在「后台账号」里建好），HTTP 4xx/5xx 也算失败。

`scripts/screenshots.cjs` 用 Playwright 依次打开所有页面（管理员、运营、审核员三种视角和窄屏），把整页 PNG 存到 `screenshots/`；浏览器控制台有 error / warning 时脚本以非 0 退出。`screenshots/real/` 是连真实后端时的截图。

## 配置

所有域名、端口、API 前缀、高德 Key 等都在 **`config.yaml`** 里（提交到仓库，是开发默认值，带中文注释），`src/` 里不写死任何环境相关的值。
`vite.config.ts` 在 dev / build / preview 启动时读取（`loadConfig.ts`），合并后逐项校验，写错（键名拼错、端口不是数字、地址不是 http(s) 等）会列出全部问题并拒绝启动，例如：

```
admin 配置有误：
  · config.local.yaml：未知配置项 dev_sever，是不是想写 dev_server？
  · backend.url 必须是 http:// 或 https:// 开头的完整地址，如 http://localhost:8080，现在是 "localhost:8083"（来自 config.local.yaml）
```

浏览器用到的部分（`api`、`amap`、`app`）在构建时通过 `define` 编进页面（常量 `__LOOPLAND_CONFIG__`），代码里只通过 `src/config.ts` 读取；`dev_server`、`preview`、`backend` 只给 Vite 用，不进页面。开发时改了配置文件会自动重启开发服务器；构建产物需要重新 build。

### 加载顺序

后面的覆盖前面的，按键深度合并，覆盖文件里只写要改的项：

1. `config.yaml`：全部键的默认值（必需）
2. `config.local.yaml`：本机覆盖（可选，已 gitignore；示例见 `config.local.example.yaml`）
3. `config.<mode>.yaml`：按 Vite mode 叠加（可选）。`pnpm run dev:mock` / `build:mock` 用 `--mode mock`，读 `config.mock.yaml`（`app.mock: true`）
4. 环境变量 `LOOPLAND_ADMIN_CONFIG=<文件路径>`：优先级最高（相对路径以 `admin/` 为准）。**设置后不再读 `config.local.yaml`**，构建结果不受开发者本机文件影响，适合测试服 / 生产构建

不再使用 `.env*` / `VITE_*` 变量（原来的 `VITE_MOCK`、`VITE_AMAP_KEY`、`VITE_AMAP_SECURITY_CODE`、`VITE_API_BASE`、`LOOPLAND_API` 分别对应 `app.mock`、`amap.key`、`amap.security_code`、`api.base_path`、`backend.url`）。

### 所有配置项

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `dev_server.host` | `localhost` | 开发服务器监听地址；局域网 / 手机访问改成 `0.0.0.0` |
| `dev_server.port` | `5173` | 开发服务器端口（1–65535 整数） |
| `dev_server.strict_port` | `false` | `true`：端口被占用直接报错；`false`：自动换下一个空闲端口 |
| `dev_server.open` | `false` | 启动后自动打开浏览器 |
| `preview.host` / `preview.port` | `localhost` / `4173` | `pnpm run preview` 的监听地址和端口 |
| `backend.url` | `http://localhost:8080` | 后端地址。dev / preview 把 `api.admin_prefix`、`api.app_prefix`、`api.ws_path`（WebSocket）代理到这里；必须是 http(s):// |
| `api.base_path` | `""` | 浏览器请求前缀。`""` = 同源（开发走代理，生产由 nginx 转发）；也可以是 `/prefix` 或 `https://api.example.com`（跨域时后端需允许 CORS） |
| `api.admin_prefix` | `/admin/v1` | 管理端接口前缀（请求和假数据路由都基于它） |
| `api.app_prefix` | `/v1` | App 接口前缀（只用于代理） |
| `api.ws_path` | `/v1/ws` | WebSocket 路径（代理开启 `ws`） |
| `amap.key` | `""` | 高德 JS API 2.0 Web 端 Key。留空时「地图与领地」用内置 SVG 地图（无底图，可缩放拖动） |
| `amap.security_code` | `""` | 高德安全密钥（明文方式，写入 `window._AMapSecurityConfig.securityJsCode`） |
| `amap.service_host` | `""` | 高德安全密钥代理地址（生产推荐，如 `https://admin.example.com/_AMapService`），填了就不再用 `security_code` |
| `amap.version` | `"2.0"` | JS API 版本，必须加引号（不加 YAML 会读成数字 2） |
| `amap.map_style` | `amap://styles/whitesmoke` | 高德底图样式 |
| `app.title` | `圈圈 Loopland · 管理端` | 浏览器标签页标题 |
| `app.mock` | `false` | `true`：所有请求走 `src/mocks` 的内存假数据（刷新页面重置），不需要后端 |

### 示例

**本机开发**：后端跑在默认的 8080 时什么都不用改，直接 `pnpm run dev`。后端在别的端口、或要打开高德底图时，新建 `config.local.yaml`：

```yaml
backend:
  url: http://localhost:8081
amap:
  key: 你的高德Key
  security_code: 你的安全密钥
```

```bash
# Linux / macOS
cp config.local.example.yaml config.local.yaml
pnpm run dev
```

```powershell
# Windows PowerShell
Copy-Item config.local.example.yaml config.local.yaml
pnpm run dev
```

**连远程测试服**：页面仍由本机 Vite 提供，API 经代理转到测试服（同源，不需要 CORS）。写一个 `config.staging.yaml`：

```yaml
backend:
  url: https://api-staging.example.com
```

```bash
# Linux / macOS
LOOPLAND_ADMIN_CONFIG=config.staging.yaml pnpm run dev
```

```powershell
# Windows PowerShell
$env:LOOPLAND_ADMIN_CONFIG = "config.staging.yaml"; pnpm run dev
Remove-Item Env:LOOPLAND_ADMIN_CONFIG   # 用完清掉，否则同一窗口里后续命令都会用它
```

也可以直接把 `backend.url` 写进 `config.local.yaml`。

**生产构建**：默认配置（`api.base_path: ""`）构建出的页面请求同源的 `/admin/v1`，由 nginx 转发到 API（见 `../deploy/admin.Dockerfile`、`../deploy/nginx-admin.conf`），镜像不需要额外配置。需要高德 Key 等生产值时，写一个生产配置并显式指定（这时不读 `config.local.yaml`）：

```yaml
# config.prod.yaml
amap:
  key: 生产高德Key
  service_host: https://admin.example.com/_AMapService
```

```bash
# Linux / macOS
LOOPLAND_ADMIN_CONFIG=config.prod.yaml pnpm run build
```

```powershell
# Windows PowerShell
$env:LOOPLAND_ADMIN_CONFIG = "config.prod.yaml"; pnpm run build; Remove-Item Env:LOOPLAND_ADMIN_CONFIG
```

注意：名为 `config.production.yaml` 的文件即使不设环境变量也会在 `pnpm run build`（mode = production）时自动叠加（第 3 层）；不想这样就换个名字。

## 页面

| 路由 | 页面 | 说明 |
| --- | --- | --- |
| `/login` | 登录 | |
| `/` | 总览 | 今日指标（与上周同期对比）、近 7 / 30 天趋势（活跃 / 跑量 / 新增领地，可切表格）、待处理事项（按优先级，「去处理」跳转） |
| `/users` | 用户管理 | 规模指标、近 30 天注册来源、搜索（昵称 / ID / 手机尾号）与筛选、详情抽屉（查看完整号码会记审计）、赠送 7 天会员 / 发通知 / 禁言 / 解禁 / 封禁 / 解封；第三批：仅管理员「查看 AI 对话」（先确认，提示查看记审计，抽屉里按时间看问答和卡片，分页） |
| `/plans` | 会员套餐与订单 | 套餐：改价、首期价、上下架、推荐、排序，右侧实时预览 App 开通页；`?tab=entitlements` 权益矩阵（锁定权益不可勾选）；`?tab=orders` 订单（按状态筛选，退款两步确认，续费失败提醒） |
| `/territories` | 地图与领地 | 城市切换、地图（高德或 SVG）、领地详情（守卫值 0–2000 步长 50、冻结 / 解冻、重置为无主、记录）、列表（全部 / 争夺中 / 已冻结，「定位」）。V2：图层开关（领地 / 怪兽 / 宝箱 / 定向打卡点，来自 `GET /admin/v1/map/objects`）；怪兽画范围圈和血条，点选后右侧可「提前结束」；**召唤怪兽**（种类、坐标可地图点选、地点名、等级、血量、半径、持续时间，默认值取玩法配置 `boss`）、**投放宝箱**、**批量撒宝箱**（当前视野 bbox + 数量 + 时长） |
| `/operations` | 玩法运营（V2） | `?tab=` bosses 城市怪兽（按状态、详情抽屉：血量、全部参与者伤害排名与每人奖励、掉落表公示、伤害规则、提前结束）· chests 宝箱（可开启 / 已过期 / 已下架，下架）· seasons 赛季（新建 / 编辑，前端先查重叠，已结算不可改；手动结算两步确认）· campaigns 限时活动（配速 / 夜跑 / 距离各自的规则字段，配速用 分:秒，未开始才能删）· routes 城市定向（2–12 个打卡点，可上下移动，右侧 SVG 预览，点地图追加点）· league 城区联赛（城区来自 `/admin/v1/districts` + 周选择，排行） |
| `/risk` | 风控防作弊 | 告警按置信度排序、证据（速度曲线超阈值标红、轨迹瞬移段标红、设备 / 定位来源 / 步频 / 心率 / 同设备账号 / 历史）、处置（作废并回滚 / 警告 / 封禁 30 天 / 误报放行）、判定规则 |
| `/gameplay` | 玩法配置 | 建筑（含 V2「图纸可越级建造」）/ 角色 / 怪兽掉落 / 能量换算；V2：怪兽（合击、投放默认值、结算、各运动伤害）、宝箱、守地、赛季段位（递增校验，显示 III/II/I 起点）、赛季任务、奖牌（type + target，累计里程同步旧字段 `distance_km`）、伙伴养成、跑团接力；第三批：**AI 跟练**（每套：key、名称、运动 跳绳 / HIIT / 普拉提·瑜伽 / 力量、难度、预计分钟、摄像头计次；每个动作：名称、计次 / 计时、目标（次 / 秒）× 组数、组间休息、姿态识别 跳跃 / 深蹲 / 俯卧撑 / 卷腹 / 不识别、语音提示、key，可上下移动、增删）和 **AI**（路线最长距离、战报字数、助手历史轮数）。改动格子高亮，未发布改动（旧值 → 新值），校验不过（掉落合计 100%、段位递增、数值范围、key 唯一）不能发布并列出原因，灰度 10% 或全量，推到全量，回滚，发布记录。V2 之前的配置缺某个分区时可「按默认值添加」 |
| `/review` | 内容审核（V2 社区 + 第三批 AI） | 顶部：待审核 / 今日已处理 / 本页高风险 / 最早等待。`?tab=` 审核队列（默认）：按 `target_type` 分 8 类（带待审数），待审核按最终风险分（规则分与 AI 分取高）排序，风险分徽标 + AI 小标（AI 分 · 建议）、被举报数、作者违规次数、文字和图片（点击放大）；详情里「规则命中」旁是 **AI 判定**（AI 分、违规类型中文、理由、置信度、建议、模型名，没有判定时说明原因）和「作者历史违规」；处理用 `POST /reviews/{id}/decide`：通过 A / 打码后通过 M / 隐藏起终点后通过 H（仅附带运动的动态）/ 驳回 R（选理由）/ 驳回并禁言 B（理由 + 天数，默认 7），AI 建议的那个按钮带「AI 建议」角标，**处理后自动跳到返回的 `next`**；本页按 AI 建议筛选（`?ai=`）、按 AI 分 / 置信度 / 提交时间排序（`?sort=`）；多选批量通过 / 驳回；已通过 / 已拒绝看审核人和时间；J/K 上下、X 勾选 · reports 举报处理（按状态和对象类型，下架可同时禁言 0–365 天，驳回）· posts 动态管理（关键词 / 作者 ID / 审核状态，详情看图片、附带运动轨迹、可见范围，下架带原因）· settings 敏感词与审核设置（仅管理员：拦截词 / 审核词标签式编辑、批量粘贴、**自动放行线 / 自动拦截线**双滑块（默认 20 / 90）、AI 审核开关、**预计每天人工量**（`GET /moderation/estimate`，拖动时防抖请求，显示每天自动放行 / 人工 / 自动拦截条数）、举报自动隐藏人数、本地「试一试」规则打分）。左侧图标显示待审核数 |
| `/community` | 组局与赛事（V2 社区） | 组局管理（状态 / 类型筛选，取消带原因）· `?tab=races` 赛事管理（线上 / 线下、运动、距离、时间窗、报名截止、线下赛地图选点、名额、穿戴设备、奖牌 key / 名称 / 图片、发布；取消；报名名单，线下赛「标记完赛」/「改成绩」） |
| `/ai-usage` | AI 用量（第三批） | 管理员 + 运营。近 7 / 14 / 30 天：调用次数、失败率、Token、估算费用（没填单价时提示去「系统配置 → AI 大模型」）、本周用完免费次数的人数；每日用量图（调用量 / 失败 / Token 输入输出 / 估算费用，可切表格）；各功能（助手对话 / 路线建议 / 运动战报 / 内容审核 / AI 跟练）调用、占比、失败率、平均耗时、Token、费用，点功能名筛调用记录；调用记录（按功能、成功 / 失败筛选，分页，只有元数据，失败的悬停看错误） |
| `/audit` | 审计日志 | 按操作人筛选 |
| `/admins` | 后台账号 | 仅管理员：新建、改角色、停用、重置密码 |

**商户与活动**（V2 第四批「本地生活与商户」，`../docs/api/v2-4-本地生活与商户.md`）：左侧一个入口 `/merchant`，页面之间用页头的分段导航切换（`src/pages/merchant/navItems.ts`，按角色隐藏）：

| 路由 | 页面 | 说明 |
| --- | --- | --- |
| `/merchant/merchants` | 商户（M-24） | 合作中 / 待签约 / 资质审核 / 暂停筛选（带数量）、搜索、今日核销；新建 / 编辑抽屉（类型、状态、联系人、联系电话（留空不改）、资质图片地址列表带预览、订场佣金 %）；详情：完整号码（仅管理员，记审计）、资质图片、场馆、投放点（只读，跳「投放」页 `/merchant/drops?merchant_id=`）、员工账号（仅管理员新建「商户对接」账号并绑定）、一键推进状态（资质审核通过 → 签约 → 暂停 / 恢复） |
| `/merchant/venues` | 场馆 | 按商户 / 运动 / 关键词筛选；新建 / 编辑（商户可空 = 只签到、运动多选、地图选点 + 坐标、城区、地址、标签、开放预订、价格、时段长度、营业时间、场地数、馆主折扣、签到半径、停用）；详情：签到二维码（浏览器用 `qrcode` 生成，可下载带场馆名的 PNG，换码二次确认）、历任馆主 |
| `/merchant/bookings` | 订场 | 按场馆 / 状态 / 开场日期筛选、详情；退款仅管理员、两步确认（填原因 → 再次确认金额和渠道） |
| `/merchant/settlement` | 核销结算（M-27） | 近 7 天核销 / 风控作废 / 订场柱状图（各自一张，可切表格）、结算单（按状态 / 商户），详情明细（核销、订场、风控作废）；确认、标记已付款、手动补生成（仅管理员） |
| `/merchant/redeem` | 核销台 | 手机优先：浏览器摄像头扫券二维码（`@zxing/browser`，按需加载，需要 HTTPS 或 localhost）或手输券码 / 扫码枪回车；成功 / 失败大卡片，把约定的错误码翻成中文；今天的核销列表。假数据模式下有测试券码 |
| `/merchant/redemptions` | 核销记录 | 按商户、日期范围；风控作废的标灰不结算 |

`/merchants`、`/venues`、`/bookings`、`/statements`、`/redemptions` 这些短链接会带着查询参数跳到对应页面。总览待办新增「商户资质」`merchant_review`、「订场退款」`booking_refund`、「结算单」`statement_confirm`。

总览增加「内容审核」卡片（`pending_reviews` 与周同比、按类型分布）和待办「内容审核」。

## 权限

菜单和按钮按当前角色隐藏或禁用，规则在 `src/auth/permissions.ts`，与后端路由守卫一致：

- 管理员：全部；只有管理员能发布 / 推全量 / 回滚玩法配置、退款、管理后台账号。
- 运营：除上述三项外的全部页面和操作（含玩法运营、内容审核、组局与赛事）；敏感词与审核设置只有管理员能看能改。
- 审核员：总览、用户（列表、详情、处置，不能看完整号码）、内容审核（队列 / 举报 / 动态）、风控；看不到玩法运营、组局与赛事、敏感词设置、AI 用量。
- 第三批「AI」：AI 用量管理员和运营都能看（单独的左侧菜单，因为系统配置只有管理员能进）；查看用户 AI 对话只有管理员，后端记审计 `ai.messages.view`。
- 商户对接（`merchant`，绑定一个商户）：登录后直接进核销台，只看到核销台、核销记录、本商户的场馆预订和结算单（只读），没有总览。
- 第四批：商户、场馆、订场列表管理员和运营都能用；完整联系电话、新建商户员工账号、订场退款、结算单（查看 / 确认 / 付款 / 生成）只有管理员；核销台管理员和运营也能代核销。

后端仍是最终裁判，越权请求返回 403，前端用消息提示。

## 目录

```
src/
  api/        类型（types.ts）、请求封装（client.ts，401 回登录页）、各接口（admin.ts；第四批 merchant.ts 商户 / 场馆 / 订场 / 核销 / 结算，perks.ts 投放 / 联名活动 / 能量商城）
  config.ts   浏览器端配置（来自 config.yaml，见「配置」）；config.types.ts 配置的类型
  mocks/      假数据和内存版接口，只在 app.mock 为 true 时按需加载；路由相对 api.admin_prefix；后端稳定后可整个删除（community.ts 社区，images.ts 内联 SVG 假图片，aiReview.ts 假 AI 审核判定 / 打码 / 预计人工量，ai.ts AI 用量、调用记录、用户 AI 对话；merchant.ts 商户、场馆、四周的核销和订场、结算单、核销台测试券码，投放数据取自 perks.ts）
  auth/       登录态、角色权限
  components/ 布局、卡片、图表、地图（map/AMapView.tsx、map/SvgMap.tsx，都画 V2 玩法对象）、MapOps.tsx（召唤 / 投放 / 撒宝箱弹窗）
  hooks/      useAdminNames（把后端返回的管理员 id 显示成用户名）、useGameplayDefaults
  pages/      各页面；operations/ 玩法运营各 tab；gameplay/config.ts 玩法配置的字段、默认值、校验与 diff；review/ 内容审核各 tab（shared.tsx 风险徽标、图片预览、原因弹窗；ai.tsx AI 判定）；community/ 组局与赛事；AIUsagePage.tsx AI 用量；users/AIMessagesDrawer.tsx 用户 AI 对话；merchant/ 商户与活动（navItems.ts 分组导航）
scripts/screenshots.cjs, scripts/screenshots-v2.cjs（devConfig.cjs 从配置里取开发服务器地址）
config.yaml, config.mock.yaml, config.local.example.yaml, loadConfig.ts（读取、合并、校验配置）
```

去掉 mock：删除 `src/mocks/`、`config.mock.yaml` 和 `package.json` 里的 `dev:mock` / `build:mock`，并删掉 `src/api/client.ts` 里 `if (MOCK) {…}` 那段。

## V2 接口与约定的出入

前端按后端实际返回兼容了这些（约定没写死或与实现不同）：

- `POST /admin/v1/chests/scatter` 的 `bbox` 是字符串 `"minLng,minLat,maxLng,maxLat"`，返回 `{"placed": n}`。
- 宝箱列表开启人数字段是 `opens`；`source` 为 `system` / `admin`；`GET /admin/v1/chests?status=` 只接受 `active` / `expired` / `removed`（其他值 400 `invalid_status`，没有「已开完」），宝箱 tab 按这三种筛选。
- 定向路线完成人数是 `finishers`；打卡点返回 `center`，提交时用扁平 `lat` / `lng`。
- 赛季没有 `status` 字段，前端按 `settled_at` 和起止时间推算；赛季、活动、路线的新建 / 修改 / 结算返回的是整个列表，前端只做刷新。
- 怪兽详情 `rewards[]` 是 `{user, rank, damage, items, energy}`。
- 夜跑专场时段后端要求 0–23 且 from < to（不跨零点），表单已按此限制。
- 城区列表来自 `GET /admin/v1/districts`（`{"items":[{"name":"徐汇区","crews":12}]}`，只含有跑团的城区，按跑团数排序），联赛页默认选第一个；接口返回空时才退回上海 16 个区的固定列表。

## V2 第二批「社区」与约定的出入

按后端实际实现兼容（`server/internal/social/admin.go`、`server/internal/community/admin.go`）：

- `GET /admin/v1/posts?q=` 只按正文模糊匹配，不按动态 ID；从审核队列跳到动态管理时用 `user_id` + `post`（打开详情），从举报跳转时用正文摘要。
- 赛事的 `medal` 总是存在：key 留空由后端生成，名称留空为「标题 完赛奖牌」，没有「不发奖牌」；有人完赛后改 key 返回 409 `medal_awarded`。赛事运动只能是跑步 / 骑行 / 徒步 / 健走，标题 ≤ 40 字。
- 已完赛的报名再调 `finish` 只改成绩、不重复发奖牌，名单里显示「改成绩」。
- 拒绝审核、下架动态不填原因时后端用默认原因；页面仍要求选择或填写，好通知作者。
- 举报处理的审计动作是 `report.handle`（`detail.action` 区分下架 / 驳回）；禁言天数后端允许 0–365。
- `pending_reviews_wow` 是比例（0.2 = +20%），上周为 0 时是 `null`。
- 页面上比后端更严的校验：线下赛报名截止不能晚于开赛；进行中的赛事不能改类型、运动、距离和开始时间；开赛前不能标记完赛。

## V2 第四批「本地生活与商户」与约定的出入

商户 / 场馆 / 订场 / 核销 / 结算部分按后端实际实现兼容（`server/internal/venue`、`server/internal/perks`）：

- 约定没写查看商户完整电话的接口，前后端用的是 `POST /admin/v1/merchants/{id}/reveal-phone` → `{"phone"}`（审计 `merchant.reveal_phone`）；后端允许运营调用，页面按约定只给管理员。
- 约定的 `Venue` 不含编辑表单要的 `slot_minutes / open_time / close_time / court_qty / is_disabled`，后端管理端列表带了这些字段（另有 `merchant_id`、`GET /admin/v1/venues/{id}`）。
- 核销记录列表后端用 `status`（`valid` / `voided`）表示风控作废，另带 `redemption_no`、`merchant`；页面同时兼容 `voided` 布尔。
- 结算单 `confirmed_by` 是 `{id, username}`；明细的 `user` 可能为 `null`。手动生成同一周重复调用时后端返回空列表而不是约定的 409。
- 登录返回的 `admin` 没有 `merchant_id`（`/me` 有），商户账号登录后前端再取一次 `/me`。
- 总览待办后端目前只有 `statement_confirm`（链接 `/merchant/settlement`）；`merchant_review`、`booking_refund` 前端已支持。约定里「订场退款申请」没有对应的订场状态，待办按「退款中」`refunding` 处理。
- 同一商户的投放可以有不同结算方向，结算单只有一个 `redemption_direction`：按净额的方向显示。

## V2 第三批「AI」与约定的出入

按后端实际实现兼容（`server/internal/social/admin.go`、`server/internal/ai/admin.go`、`server/internal/moderation`）：

- `POST /admin/v1/reviews/{id}/decide` 返回 `{"task": ReviewTask, "next": ReviewTask | null}`；带 `?target_type=` 时 `next` 只取同类型（队列按类型筛选时页面会带上）。审计动作是 `review.<action>`（`review.approve_masked`、`review.reject_mute` 等）。没附运动的动态做「隐藏起终点后通过」返回 400 `not_supported`。
- 「打码后通过」改的是动态正文，审核记录里的 `text` 仍是提交时的原文。
- 自动拦截线必须**高于**自动放行线（相等也 400），`GET /moderation/estimate` 同样校验；页面按此限制。`ai_enabled` 每次保存都显式带上（后端缺省会读成 false）。
- 查看用户 AI 对话的审计动作是 `ai.messages.view`。
- 「AI 建议」筛选和排序只作用于已加载的这一页：`GET /reviews` 没有按 AI 建议的参数。
- 跟练动作按时长计时 `target` 的单位是秒；`chat_history_turns` 0–20、`route_max_km` 不超过 100、`report_max_chars` 20–500（和后端校验一致）。

