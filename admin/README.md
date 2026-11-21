# 圈圈 Loopland · 管理端（V1 + V2 第一批「玩法深化」）

运营后台。技术栈：Vite 6 + React 18 + TypeScript（strict）+ Ant Design 5 + react-router 6 + ECharts 5 + TanStack Query 5。
接口约定见 `../docs/api/v1.md`「管理端」一节和 `../docs/api/v2-1-玩法.md`（「管理端」与玩法配置新增字段），类型和请求函数手写在 `src/api/`。

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

V2 页面另有一套：`pnpm run screenshots:v2`，存到 `screenshots/v2/`（会在内存假数据里召唤怪兽、撒宝箱、建活动）。连真实后端时加 `SHOT_DIR=real-v2 ADMIN_PASSWORD=admin-password-1 STAFF_PASSWORD=<xiaolin / amei 的密码>`（这两个账号需先在「后台账号」里建好），HTTP 4xx/5xx 也算失败。

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
| `/users` | 用户管理 | 规模指标、近 30 天注册来源、搜索（昵称 / ID / 手机尾号）与筛选、详情抽屉（查看完整号码会记审计）、赠送 7 天会员 / 发通知 / 禁言 / 解禁 / 封禁 / 解封 |
| `/plans` | 会员套餐与订单 | 套餐：改价、首期价、上下架、推荐、排序，右侧实时预览 App 开通页；`?tab=entitlements` 权益矩阵（锁定权益不可勾选）；`?tab=orders` 订单（按状态筛选，退款两步确认，续费失败提醒） |
| `/territories` | 地图与领地 | 城市切换、地图（高德或 SVG）、领地详情（守卫值 0–2000 步长 50、冻结 / 解冻、重置为无主、记录）、列表（全部 / 争夺中 / 已冻结，「定位」）。V2：图层开关（领地 / 怪兽 / 宝箱 / 定向打卡点，来自 `GET /admin/v1/map/objects`）；怪兽画范围圈和血条，点选后右侧可「提前结束」；**召唤怪兽**（种类、坐标可地图点选、地点名、等级、血量、半径、持续时间，默认值取玩法配置 `boss`）、**投放宝箱**、**批量撒宝箱**（当前视野 bbox + 数量 + 时长） |
| `/operations` | 玩法运营（V2） | `?tab=` bosses 城市怪兽（按状态、详情抽屉：血量、全部参与者伤害排名与每人奖励、掉落表公示、伤害规则、提前结束）· chests 宝箱（可开启 / 已过期 / 已下架，下架）· seasons 赛季（新建 / 编辑，前端先查重叠，已结算不可改；手动结算两步确认）· campaigns 限时活动（配速 / 夜跑 / 距离各自的规则字段，配速用 分:秒，未开始才能删）· routes 城市定向（2–12 个打卡点，可上下移动，右侧 SVG 预览，点地图追加点）· league 城区联赛（城区来自 `/admin/v1/districts` + 周选择，排行） |
| `/risk` | 风控防作弊 | 告警按置信度排序、证据（速度曲线超阈值标红、轨迹瞬移段标红、设备 / 定位来源 / 步频 / 心率 / 同设备账号 / 历史）、处置（作废并回滚 / 警告 / 封禁 30 天 / 误报放行）、判定规则 |
| `/gameplay` | 玩法配置 | 建筑（含 V2「图纸可越级建造」）/ 角色 / 怪兽掉落 / 能量换算；V2：怪兽（合击、投放默认值、结算、各运动伤害）、宝箱、守地、赛季段位（递增校验，显示 III/II/I 起点）、赛季任务、奖牌（type + target，累计里程同步旧字段 `distance_km`）、伙伴养成、跑团接力。改动格子高亮，未发布改动（旧值 → 新值），校验不过（掉落合计 100%、段位递增、数值范围、key 唯一）不能发布并列出原因，灰度 10% 或全量，推到全量，回滚，发布记录。V2 之前的配置缺某个分区时可「按默认值添加」 |
| `/audit` | 审计日志 | 按操作人筛选 |
| `/admins` | 后台账号 | 仅管理员：新建、改角色、停用、重置密码 |

内容审核、商户与活动还没做，左侧菜单里显示为灰色「V2」。

## 权限

菜单和按钮按当前角色隐藏或禁用，规则在 `src/auth/permissions.ts`，与后端路由守卫一致：

- 管理员：全部；只有管理员能发布 / 推全量 / 回滚玩法配置、退款、管理后台账号。
- 运营：除上述三项外的全部页面和操作（含玩法运营）。
- 审核员：总览、用户（列表、详情、处置，不能看完整号码）、风控；看不到玩法运营。
- 商户对接：V1 只有总览。

后端仍是最终裁判，越权请求返回 403，前端用消息提示。

## 目录

```
src/
  api/        类型（types.ts）、请求封装（client.ts，401 回登录页）、各接口（admin.ts）
  config.ts   浏览器端配置（来自 config.yaml，见「配置」）；config.types.ts 配置的类型
  mocks/      假数据和内存版接口，只在 app.mock 为 true 时按需加载；路由相对 api.admin_prefix；后端稳定后可整个删除
  auth/       登录态、角色权限
  components/ 布局、卡片、图表、地图（map/AMapView.tsx、map/SvgMap.tsx，都画 V2 玩法对象）、MapOps.tsx（召唤 / 投放 / 撒宝箱弹窗）
  hooks/      useAdminNames（把后端返回的管理员 id 显示成用户名）、useGameplayDefaults
  pages/      各页面；operations/ 玩法运营各 tab；gameplay/config.ts 玩法配置的字段、默认值、校验与 diff
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
