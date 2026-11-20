# 圈圈 Loopland

跑一圈，就是你的地。Run a loop. Own the land.

用跑步和各种运动在真实城市地图上圈地、建城、收集角色，和跑团一起抢地盘、打城市怪兽。

## 仓库结构

| 路径 | 内容 | 状态 |
| --- | --- | --- |
| `docs/资料包/` | 产品文档、技术选型、功能清单、交互原型、界面截图、Logo 与图标 | 设计输入，打开 `02_交互原型/打开我.html` 看原型 |
| `server/` | Go 后端（分模块单体） | 进行中 |
| `server/migrations/` | PostgreSQL 16 + PostGIS 表结构 | 初版 |
| `deploy/` | 本地开发用的 PostGIS、Redis | 可用 |
| `app/` | Flutter 客户端 | 未开始 |
| `admin/` | React 管理端 | 未开始 |

## 后端

```
server/
  cmd/loopland-api/      HTTP 服务入口
  internal/geo/          平面投影、线段相交、面积
  internal/claim/        自由圈地：轨迹自交即闭合，一次运动可圈多块，「还差多少米可闭合」
  internal/gameplay/     玩法数值（建筑、角色、怪兽掉落、能量换算）和规则（日上限、建城、守卫、抢地判定）
  internal/httpapi/      接口
  migrations/            表结构
```

接口：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/healthz` | 健康检查 |
| GET | `/v1/config/gameplay` | 当前玩法数值 |
| POST | `/v1/claims/preview` | 传入 `{sport, points:[{lat,lng}]}`，返回圈到的地块、面积、距离、能量 |

本地运行：

```bash
make test
make run          # 监听 :8080，可用 LOOPLAND_HTTP_ADDR 修改
make dev-up       # 启动 PostGIS 和 Redis（需要 Docker）
```

## 圈地算法

维护一条「开放路径」：已走过的轨迹去掉已经圈下的部分。每来一个新点，用新线段和开放路径上不相邻的线段求交。
沿新线段最先碰到的交点 X，加上被交线段之后的那段路径，就是一个简单多边形，即圈下的地。把这段从路径里切掉，
路径停在 X，再继续检查剩下的线段，所以一段长线段也能一次圈下好几块。小于最小面积的圈（多为 GPS 抖动）
会被切掉但不算领地。

客户端在跑步中用同样的算法做预览；结算以服务端为准，之后再用 PostGIS 与别人的领地求差集、做抢地判定。
