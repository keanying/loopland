# 圈圈 Loopland · 项目约定

运动 + 游戏化 App：跑步圈地、建城、城市怪兽、跑团。三端：`server/`（Go 1.26 + PostgreSQL/PostGIS + Redis）、`admin/`（React + TS + Ant Design）、`app/`（Flutter）。

## 必须遵守

- **数据库命名**：严格按 `docs/数据库与命名规范.md`。要点：
  - 业务表在 `src` schema，表名 `src_<业务域>_<实体>`，业务域前缀 `usr_ act_ ter_ ply_ soc_ ord_ fin_ mer_ mkt_ ris_ cnt_ msg_ trf_ sys_`。
  - SQL 里一律写 `src.src_xxx`（schema.表），不写裸表名。
  - 字段关键字：时间 `_time`（timestamptz）、日期 `_date`、金额 `_amt`（单位分）、编号 `_no`、类型 `_type`、状态 `_status`、数量 `_qty`、比例 `_rate`、布尔 `is_`、距离 `_m`、面积 `_m2`、时长 `_sec`。
  - 每张表、每个字段都要有 `COMMENT`；类型/状态字段的注释要写清每个取值的含义。
  - 不用拼音。
  - 数仓分层 `src/ods/dwd/dws/ads/dim`，粒度后缀 `_di/_df/_wk/...`，分区字段 `sport_date`（YYYYMMDD）。
- **配置**：
  - 系统级配置（端口、数据库、缓存、JWT、数据加密密钥）放 `server/config.yaml`；`admin/config.yaml`、`app/config/app.yaml` 放前端的域名、端口、API 地址。
  - 第三方服务（短信、验证码、一键登录、实名、微信、支付宝、Apple、AI、邮件、地图等）的 Key 在**管理端「系统配置」页面**维护，加密存库，不写进代码和配置文件。
- **接口约定**：`docs/api/*.md` 是前后端共同的契约；改接口要同步改文档。JSON 字段名与数据库字段名相互独立。
- **密钥**：不提交到仓库，不发到聊天里。
- **测试**：后端 `cd server && go test ./...`（需要本机 PostgreSQL+PostGIS 和 Redis）；管理端 `npm run lint && npm run build`；App `flutter analyze && flutter test`。
- 本地启动见 `docs/本地启动.md`（Linux / Windows），上线接入见 `docs/上线接入清单.md`。
