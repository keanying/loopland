# 圈圈 Loopland

跑一圈，就是你的地。Run a loop. Own the land.

用跑步和各种运动在真实城市地图上圈地、建城、收集角色，和跑团一起抢地盘。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `docs/资料包/` | 产品文档、技术选型、功能清单、交互原型、界面截图、Logo 与图标 |
| `docs/api/v1.md` | **V1 接口约定**（前后端共同遵守），含 V1 / V2 范围划分 |
| `docs/调研/` | 登录与支付依赖选型 |
| `server/` | Go 后端（分模块单体）+ PostgreSQL/PostGIS + Redis |
| `admin/` | 管理端：React + TypeScript + Ant Design，见 `admin/README.md` |
| `app/` | App：Flutter + Riverpod，见 `app/README.md` |
| `deploy/` | 本地开发用 docker-compose（PostGIS、Redis、API） |

## 快速开始

```bash
make dev-up      # 启动 PostGIS、Redis 和 API（dev 模式，管理员 admin / admin-password-1）
make seed        # 灌入演示数据：6 个用户、圈地、抢地、作弊记录、跑团、会员订单
```

不用 Docker 时：本机有 PostgreSQL 16 + PostGIS 和 Redis，执行 `make run`。

dev 模式下：短信验证码固定 `000000`；一键登录 token 写 `dev:13800138000`；微信 code 写 `dev:<openid>`；Apple token 写 `dev:<sub>`；支付可用 `mock` 渠道。

## 后端模块（server/internal）

| 模块 | 职责 |
| --- | --- |
| `claim`、`geo` | 自由圈地：轨迹自交即闭合，一次可圈多块，「还差多少米可闭合」 |
| `territory` | PostGIS 结算：抢地、削弱、整块夺取、作弊回滚、视野查询、建城、驻扎 |
| `activity`、`anticheat` | 运动上传、风控判定（放行 / 人工复核 / 自动作废）、能量与日上限 |
| `auth`、`user` | 短信、一键登录、微信、Apple；手机号加密存储；隐私授权、实名、注销、导出 |
| `billing` | 套餐、订单、微信支付 V3、支付宝、Apple 内购、回调、退款、续费 |
| `codex`、`crew`、`inbox` | 图鉴、跑团、站内消息 |
| `gameplay` | 玩法数值，带版本、灰度和回滚 |
| `admin` | 管理端接口：4 种角色、审计日志 |
| `jobs` | 续费、扣费提醒、关闭超时订单、领地每日产能、注销到期清理 |

## 测试

```bash
make test                                      # 后端：单元 + PostGIS 集成 + 端到端（需要本机 PostgreSQL、Redis）
cd admin && npm run lint && npm run build      # 管理端
cd app && flutter analyze && flutter test      # App
LOOPLAND_LIVE_API=http://localhost:8080 flutter test integration_live   # App 接真实后端联调
```

## 接入真实服务

见 **`docs/上线接入清单.md`**：每家服务去哪申请、拿到什么、填到哪里。后端配置 `server/config.yaml`（本地）/ `server/config.prod.example.yaml`（正式环境模板）；配好后运行 `make doctor`（或部署环境里的 `loopland-doctor`）逐项验证密钥。正式环境缺配置会拒绝启动并列出缺项。

## 上线前需要准备

- 微信开放平台（App 登录 + 微信支付 V3）、支付宝 App 支付、Apple（登录 + 内购 + 服务器通知）、阿里云短信与号码认证、高德地图 key：代码已接好，只缺商户资质和密钥（环境变量见 `server/internal/platform/config`）。
- 实名核验（持牌服务）、人机验证：接口已留，需要接入服务商。
- 微信 / 支付宝连续包月需开通委托代扣、周期扣款；V1 先做到期提醒，iOS 由 Apple 自动续费。
- 合规：ICP 与 App 备案、个人信息保护、生成式 AI 登记（V2 上 AI 前）等，见技术选型文档。
