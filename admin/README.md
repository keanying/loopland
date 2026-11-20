# 圈圈 Loopland · 管理端（V1）

运营后台。技术栈：Vite 6 + React 18 + TypeScript（strict）+ Ant Design 5 + react-router 6 + ECharts 5 + TanStack Query 5。
接口约定见 `../docs/api/v1.md`「管理端」一节，类型和请求函数手写在 `src/api/`。

## 运行

```bash
cd admin
npm ci

# 连真实后端：Vite 把 /admin 和 /v1 代理到 http://localhost:8080
npm run dev            # http://localhost:5173

# 假数据模式：不需要后端（等同于 VITE_MOCK=1）
npm run dev:mock       # 账号 admin / xiaolin / amei / shop，密码任意（"wrong" 会失败）

# 构建（先 tsc --noEmit，再 vite build，产物在 dist/）
npm run build
npm run lint           # eslint，0 warning
```

后端本地启动（见 `../server`）：`LOOPLAND_ENV=dev LOOPLAND_BOOTSTRAP_ADMIN='admin:admin-password-1' go run ./cmd/loopland-api`，然后用 admin / admin-password-1 登录。

### 截图

```bash
npm run dev:mock                                  # 终端 1
BASE_URL=http://localhost:5173 npm run screenshots  # 终端 2
```

`scripts/screenshots.cjs` 用 Playwright 依次打开所有页面（管理员、运营、审核员三种视角和窄屏），把整页 PNG 存到 `screenshots/`；浏览器控制台有 error / warning 时脚本以非 0 退出。`screenshots/real/` 是连真实后端时的截图。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `VITE_MOCK` | `1` 时所有请求走 `src/mocks/` 里的内存假数据（刷新页面会重置）。`npm run dev:mock` 通过 `.env.mock` 自动打开 |
| `VITE_AMAP_KEY` | 高德 JS API 2.0 Key。设置后「地图与领地」用高德底图画领地；不设置时用内置 SVG 渲染（无底图，可缩放拖动） |
| `VITE_AMAP_SECURITY_CODE` | 高德安全密钥（可选，对应 `window._AMapSecurityConfig`） |
| `VITE_API_BASE` | API 前缀，默认空（同源，由代理或网关转发） |
| `LOOPLAND_API` | 仅开发服务器使用：代理目标，默认 `http://localhost:8080` |

本地覆盖写在 `.env.local`（已 gitignore），示例见 `.env.example`。

## 页面

| 路由 | 页面 | 说明 |
| --- | --- | --- |
| `/login` | 登录 | |
| `/` | 总览 | 今日指标（与上周同期对比）、近 7 / 30 天趋势（活跃 / 跑量 / 新增领地，可切表格）、待处理事项（按优先级，「去处理」跳转） |
| `/users` | 用户管理 | 规模指标、近 30 天注册来源、搜索（昵称 / ID / 手机尾号）与筛选、详情抽屉（查看完整号码会记审计）、赠送 7 天会员 / 发通知 / 禁言 / 解禁 / 封禁 / 解封 |
| `/plans` | 会员套餐与订单 | 套餐：改价、首期价、上下架、推荐、排序，右侧实时预览 App 开通页；`?tab=entitlements` 权益矩阵（锁定权益不可勾选）；`?tab=orders` 订单（按状态筛选，退款两步确认，续费失败提醒） |
| `/territories` | 地图与领地 | 城市切换、地图（高德或 SVG）、领地详情（守卫值 0–2000 步长 50、冻结 / 解冻、重置为无主、记录）、列表（全部 / 争夺中 / 已冻结，「定位」） |
| `/risk` | 风控防作弊 | 告警按置信度排序、证据（速度曲线超阈值标红、轨迹瞬移段标红、设备 / 定位来源 / 步频 / 心率 / 同设备账号 / 历史）、处置（作废并回滚 / 警告 / 封禁 30 天 / 误报放行）、判定规则 |
| `/gameplay` | 玩法配置 | 建筑 / 角色 / 怪兽掉落 / 能量换算，改动格子高亮，未发布改动（旧值 → 新值），掉落合计 100% 才能发布，灰度 10% 或全量，推到全量，回滚，发布记录 |
| `/audit` | 审计日志 | 按操作人筛选 |
| `/admins` | 后台账号 | 仅管理员：新建、改角色、停用、重置密码 |

内容审核、商户与活动是 V2，左侧菜单里显示为灰色「V2」。

## 权限

菜单和按钮按当前角色隐藏或禁用，规则在 `src/auth/permissions.ts`，与后端路由守卫一致：

- 管理员：全部；只有管理员能发布 / 推全量 / 回滚玩法配置、退款、管理后台账号。
- 运营：除上述三项外的全部页面和操作。
- 审核员：总览、用户（列表、详情、处置，不能看完整号码）、风控。
- 商户对接：V1 只有总览。

后端仍是最终裁判，越权请求返回 403，前端用消息提示。

## 目录

```
src/
  api/        类型（types.ts）、请求封装（client.ts，401 回登录页）、各接口（admin.ts）
  mocks/      假数据和内存版接口，只在 VITE_MOCK=1 时按需加载；后端稳定后可整个删除
  auth/       登录态、角色权限
  components/ 布局、卡片、图表、地图（map/AMapView.tsx、map/SvgMap.tsx）
  hooks/      useAdminNames（把后端返回的管理员 id 显示成用户名）
  pages/      各页面
scripts/screenshots.cjs
```

去掉 mock：删除 `src/mocks/`、`.env.mock`，并删掉 `src/api/client.ts` 里 `if (MOCK) {…}` 那段。
