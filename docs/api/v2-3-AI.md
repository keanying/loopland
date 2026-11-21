# 圈圈 Loopland · V2 第三批「AI」API 约定

在 `docs/api/v1.md`、`v2-1-玩法.md`、`v2-2-社区.md` 的基础上增加。通用约定不变。

## 范围（功能清单）

| 编号 | 功能 | 本批做什么 |
| --- | --- | --- |
| E-08 | AI 助手圈圈 | 对话式助手：去哪抢地、怪兽怎么打、今天跑多少合适；回答里的路线卡片可一键开跑；可发图片（需配置视觉模型）；公示模型名称和备案号；回答标注「AI 生成」；免费用户每周 3 次，会员（权益 `ai_coach_unlimited`）不限 |
| C-04 | AI 路线建议 | 开跑页「本次目标」：AI 推荐闭环、夺回 / 守卫某块地、顺路打怪兽。**规则算法生成候选路线，大模型只负责一句话解释** |
| C-05 / D-05 | AI 战报 | 运动结算后生成一段战报（小模型），可一键带进发布动态，动态里单独展示并标注 AI 生成 |
| C-09 | AI 跟练 | 居家训练（跳绳 / HIIT / 普拉提·瑜伽 / 力量）：动作库、按动作引导、摄像头姿态识别自动计次（端上 ML Kit，不上传画面）、计时、语音提示节奏；只换能量 |
| A-04 | 问 AI | 领地卡片、怪兽卡片上的「问 AI」，带着对象打开助手 |
| M-16 ~ M-19 | AI 审核 | 文本（以及配置了视觉模型时的图片）由大模型打风险分、给判定理由、置信度和处理建议；规则分与 AI 分取高；自动放行线 / 自动拦截线；预计每天人工量；新的处理动作 |
| — | AI 用量 | 管理端看各功能调用量、Token、失败率、耗时、估算费用 |

## 模型与合规

- 模型来自管理端「系统配置 → AI 大模型」（`docs/api/系统配置.md`，OpenAI 兼容接口）。本批给它新增两个可选字段：`vision_model`（视觉模型，如 `qwen-vl-plus`；空 = 不支持图片）和 `price_input_per_mtok_fen` / `price_output_per_mtok_fen`（每百万 Token 单价，单位分，只用于估算费用）。
- **开发环境没配 AI 时**使用内置的「模拟 AI」（固定模板回答，`model_name` 为「开发环境模拟 AI」），所有功能可演示；正式环境没配或停用时，相关接口返回 503 `ai_unavailable`，`GET /v1/config/features` 的 `ai=false`，App 隐藏入口。
- 所有 AI 生成的文字在接口里都带 `"ai_generated": true`，App 必须在旁边显示「内容由 AI 生成」标识；助手页顶部或「关于」里公示 `model_name` 和 `registration_no`（《生成式人工智能服务管理暂行办法》、《人工智能生成合成内容标识办法》）。
- 用户输入先过敏感词（`moderation` 拦截级直接拒绝，400 `content_blocked`）；模型输出也过一遍敏感词，命中拦截级时整段替换为「这个问题圈圈暂时回答不了」。
- 对话内容保存 180 天（用于投诉核查），用户可清空自己的对话（软删除，后台仍保留到期）。
- AI 调用失败、超时（`timeout_s`）不扣次数。

---

## App · AI 信息与额度

### GET /v1/ai/info
```json
{
  "enabled": true,
  "model_name": "通义千问",
  "registration_no": "Beijing-XXXX-20240101",
  "vision": false,
  "disclaimer": "内容由 AI 生成，仅供参考",
  "quota": { "unlimited": false, "weekly_free": 3, "used": 1, "remaining": 2, "resets_at": "2026-11-23T16:00:00Z" }
}
```
- 周一 00:00（Asia/Shanghai）重置，`resets_at` 为 UTC 时间。会员（有效会员且权益含 `ai_coach_unlimited`，续费失败的 3 天宽限期内仍算）`unlimited=true`，`remaining=null`。
- 正式环境没配 AI 时此接口仍返回 200：`enabled=false`、`model_name`/`registration_no` 为 `""`。
- 只有「助手对话」扣次数；路线建议、战报、跟练、审核都不扣。

---

## App · AI 助手（E-08、A-04）

**AIMessage**：
```json
{
  "id": 31, "role": "user | assistant",
  "content": "今晚去哪抢地？",
  "image_url": null,
  "cards": [ Card ],
  "ai_generated": true,
  "created_at": "..."
}
```
`role=user` 时 `cards=[]`、`ai_generated=false`。

**Card**（助手回答里可点的卡片）：
```json
{ "type": "route", "route": Route }
{ "type": "territory", "territory": { "id": 12, "name": "西岸草坪", "owner": { "id": 3, "nickname": "..." }, "crew": { "id": 2, "name": "城西跑团" }, "guard": 42, "center": { "lat": 31.2, "lng": 121.4 } } }
{ "type": "boss", "boss": { "id": 5, "name": "沙发怪", "hp": 1200, "max_hp": 5000, "center": { "lat": 31.2, "lng": 121.4 }, "ends_at": "..." } }
```

### GET /v1/ai/greeting?lat=&lng= → `{"text":"晚上好阿杰！今天你已经拿了 320 能量……","suggestions":["规划圈地路线","今晚去哪抢地","生成今日战报","帮我排一周计划"],"ai_generated":false}`
开场白用模板拼（今天能量、跑团状态、附近怪兽），不调模型、不扣次数。

### GET /v1/ai/messages?before=<id>&limit=30 → `{"items":[AIMessage],"next_cursor"}`（倒序翻历史）
### DELETE /v1/ai/messages → `{}`（清空对话）

### POST /v1/ai/chat
```json
{
  "content": "今晚去哪抢地？",
  "image_id": 12,
  "context": { "type": "territory | boss", "id": 12 },
  "lat": 31.23, "lng": 121.47
}
```
- `content` 1–500 字；`image_id` 为本人上传的图片（`purpose=chat`），没配视觉模型时 400 `ai_image_unsupported`；`context` 来自「问 AI」；`lat/lng` 可选，用于找附近的地和怪兽。
- 免费额度用完：429 `ai_quota_exceeded`（message：「本周免费次数已用完，开通会员不限次数」）。每人每分钟最多 6 次（429 `rate_limited`）；上一个问题还在回答时再问也是 429 `rate_limited`。
- 其他错误：`content` 为空或超过 500 字 400 `invalid_content`；`image_id` 不是本人上传的图片 400 `invalid_media`；`context.type` 取值错误或坐标不合法 400 `invalid_body`；`context` 指向的领地 / 怪兽不存在 404 `not_found`。
- 带图片时由视觉模型回答（不调用工具）；`context` 和最近 `chat_history_turns` 轮对话会带给模型。

**流式返回**（请求头 `Accept: text/event-stream`，推荐）：
```
event: delta
data: {"text":"往东"}

event: delta
data: {"text":"绕滨江公园一圈"}

event: card
data: {"type":"route","route":{...}}

event: done
data: {"message": AIMessage, "user_message": AIMessage, "quota": {...}}
```
出错时 `event: error`，`data: {"code":"ai_unavailable","message":"..."}`，然后结束（不扣次数、不保存）。
- 参数、额度、频率这类**开始生成前**的错误即使请求了流式也按普通 HTTP 错误返回（状态码 + JSON 错误体）；`event: error` 只出现在流已开始之后。
- `card` 在工具返回时立即推送；`done.message` 是最终结果，**以它为准**：输出命中拦截词时 delta 会提前停止，`done.message.content` 为「这个问题圈圈暂时回答不了」且 `cards=[]`。
**非流式**（`Accept: application/json`）：`→ {"message": AIMessage, "user_message": AIMessage, "quota": {...}}`。

**助手能做什么**（后端用工具调用拿真实数据，不编造）：
| 工具 | 数据 |
| --- | --- |
| 我的状态 | 今日 / 本周能量、里程、领地数、跑团、本周排名、最近被攻击的地 |
| 附近目标 | 附近守卫值低的别人的地、我被攻击待加固的地、我丢掉的地 |
| 附近怪兽 / 宝箱 | 正在出没的怪兽（血量、剩余时间）、未开的宝箱 |
| 规划路线 | 调用下面的路线建议算法，返回路线卡片 |
| 玩法规则 | 当前玩法配置（能量换算、合击、守地等）的要点 |
| 训练建议 | 最近 4 周运动量 → 今天建议跑多少（只给一般性建议，不做医疗判断，身体不适提示就医） |

---

## App · AI 路线建议（C-04）

### GET /v1/ai/routes?lat=&lng=&sport=run&distance_km=5 → `{"items":[Route],"ai_generated":true}`

**Route**：
```json
{
  "id": "r_8f2c1a",
  "type": "loop | capture | defend | boss",
  "title": "AI 推荐闭环",
  "subtitle": "绕滨江公园一圈，回到起点圈下约 0.4 km²",
  "reason": "你最近 5 公里配速 6'10\"，这一圈约 32 分钟，途经两块守卫值很低的地。",
  "distance_m": 5200, "est_duration_sec": 1920, "est_area_m2": 400000,
  "waypoints": [ { "lat": 31.23, "lng": 121.47 } ],
  "polyline": [ [121.47, 31.23], [121.48, 31.24] ],
  "targets": [ { "type": "territory | boss | chest", "id": 12, "name": "西岸草坪", "lat": 31.2, "lng": 121.4, "note": "「城西跑团」占领 · 守卫值 42，较易夺回" } ],
  "ai_generated": true
}
```
- 最多 4 条，顺序：`loop`（按目标距离或近 4 周平均距离规划的闭环，起终点为当前位置）→ `capture`（最划算的一块：守卫值低、离得近）→ `defend`（我被攻击、还在 24 小时加固期的地）→ `boss`（附近正在出没的怪兽）。没有对应目标的类型不出现。
- 路线由规则算法生成：候选目标按「收益 / 距离」打分，闭环用多边形近似保证回到起点并控制长度在目标距离 ±25%。配置了「高德 Web 服务」时 `polyline` 用高德步行 / 骑行路径规划贴合道路；没配时是航点之间的直线。
- `reason` 由小模型写一句话；AI 不可用时用模板句，此时该条 `ai_generated=false`。结果按（用户, 约 200 m 网格, 运动类型, 距离）缓存 10 分钟。
- 参数：`lat`/`lng` 必填，`sport` 为 `run`（默认）/ `ride` / `hike` / `walk`，`distance_km` 可选（0 到玩法配置 `ai.route_max_km`），否则 400 `invalid_body`。路线是规则算法生成的，**没配模型时也能用**（全部用模板句，顶层 `ai_generated` 为是否有任一条由模型解释）。
- `loop` 的 `targets` 是闭环途经的守卫值低的地；高德路径规划失败的路段退回直线。
- 选中路线开跑：`POST /v1/activities` 的 `goal` 写 `{"type":"ai_route","route_id":"r_8f2c1a","route_type":"loop"}`，用于统计采纳率；圈地规则不变。`type=ai_route` 时 `route_id` 必填、`route_type` 只能是 `loop`/`capture`/`defend`/`boss`，否则 400 `invalid_body`。

---

## App · AI 战报（C-05、D-05）

### POST /v1/activities/{id}/ai-report?regenerate=0 → AIReport
```json
{ "activity_id": 55, "text": "今晚 5.2 公里，配速 6'05\"，一口气圈下滨江两块地……", "model_name": "通义千问", "ai_generated": true, "generated_at": "...", "regenerate_left": 2 }
```
- 只能给自己已结算的运动生成（别人的或不存在 404 `not_found`，未结算 400 `invalid_activity`）。第一次生成后保存，再次请求直接返回；`regenerate=1` 重新生成，每次运动最多 2 次（之后 409 `regenerate_limit`）。模型不可用或调用失败 503 `ai_unavailable`。
- 输入给模型的只有本次运动数据（距离、时长、配速、圈地、抢地、怪兽、宝箱、任务、伙伴、集结跑、赛事），不含轨迹坐标。
- 战报 ≤ 120 字，口吻积极，不编造数据。

**发布动态带战报**：`POST /v1/posts` 新增可选 `"ai_report": true`（必须同时带 `activity_id` 且该运动已生成战报）。`Post` 新增字段：
```json
"ai_report": { "text": "...", "ai_generated": true }
```
没带时为 `null`。战报正文不计入 500 字，也走审核。没带 `activity_id` 或该运动还没有战报：400 `invalid_ai_report`。

---

## App · AI 跟练（C-09）

### GET /v1/ai/workouts → `{"items":[Workout]}`
```json
{
  "key": "rope_basic", "name": "跳绳入门", "sport": "rope", "level": "beginner | intermediate | advanced",
  "cover_url": null, "est_minutes": 12,
  "camera": true,
  "steps": [
    { "key": "rope_jump", "name": "双脚跳", "mode": "count | time", "target": 100, "rest_sec": 30, "sets": 5,
      "pose": "jump", "cue": "保持节奏，落地轻一点", "demo_url": null }
  ]
}
```
- 不调用模型（正式环境没配 AI 也能返回）。
- 动作库来自玩法配置新增的 `workouts` 段（管理端「玩法配置」可编辑，带默认值：跳绳入门、HIIT 燃脂、普拉提核心、力量入门各一套）。
- `pose` 告诉 App 用哪种姿态计次规则：`jump`（跳绳 / 开合跳：髋部上下周期）、`squat`（深蹲：膝角）、`pushup`（俯卧撑：肘角）、`crunch`（卷腹）、`none`（只计时）。

**计次在 App 端完成**：Google ML Kit 姿态识别在本机运行，画面不上传、不保存。没有摄像头权限或识别不稳时退回手动计次 / 只计时。

**上传**：沿用 `POST /v1/activities`（`sport` 为 `rope` / `hiit` / `yoga` / `strength`，`amount` 为次数或分钟），新增可选：
```json
"coach": { "workout_key": "rope_basic", "camera": true, "reps_detected": 480, "reps_manual": 0, "sets_done": 5 }
```
服务端按原有规则换能量（只换能量、不圈地），`coach.camera=true` 且识别次数与上报一致时不触发「居家训练手动上报」的风控复核阈值（风控里新增规则 `coach_mismatch`：上报次数比识别次数多 20% 以上进入复核）。
- 「上报次数」：跳绳（按次计）为 `amount`；按分钟计的运动为 `reps_detected + reps_manual`。差距不到 5 次不算；`camera=false` 不检查。
- `coach` 只能用于居家运动，数值不能为负，否则 400 `invalid_body`。

---

## 内容审核升级（M-16 ~ M-19）

### AI 打分
- 送审时（动态、评论、昵称、简介、跑团名称、组局）同步请求小模型做分类，超时 3 秒；超时或失败先按规则分处理，并在后台补打分（补打分结果更高时，已自动通过的内容会转回待审核）。
- 有视觉模型时，动态图片、头像、跑团头像也送去识别。
- 模型返回：
```json
{ "risk_score": 85, "labels": ["ad", "contact"], "reason": "正文引导添加微信并售卖代跑服务", "confidence": 0.92, "suggestion": "reject | review | approve | mask | hide_endpoints" }
```
labels 取值：`ad`-广告引流 `contact`-联系方式 `porn`-色情 `politics`-涉政 `abuse`-辱骂 `fraud`-诈骗 `illegal`-违法 `privacy`-隐私泄露（如轨迹暴露住址） `minor`-未成年人 `other`。
- 最终风险分 = max(规则分, AI 分)。
- 打分记录：自动通过、自动拒绝的内容也记一条审核任务（`status` 为 `approved` / `rejected`，`reviewer=null`），用于补打分和 `estimate`；`GET /admin/v1/reviews` 新增可选 `decision=manual|auto` 过滤已处理的任务；`/reviews/stats` 的 `today_done` 只算人工处理。

### 阈值（M-19）
「敏感词与审核设置」新增：
```json
{ "auto_approve_below": 20, "auto_reject_above": 90, "ai_enabled": true }
```
- 风险分 < 自动放行线：直接通过；≥ 自动拦截线：直接拒绝（通知作者，可申诉 = 重新编辑发布）；之间进人工队列。默认 20 / 90（第二批的默认 30 改为 20）。
  - 动态、评论、组局被自动拒绝时照常创建，`review_status=rejected`、`reject_reason` 说明原因，并发 `review_rejected` 站内信。
  - 昵称、头像、简介、跑团名称和头像仍是「先生效后审核」、全部进队列；达到自动拦截线时直接 400 `content_blocked`（不生效）。
- `PUT /admin/v1/moderation/settings` 没传的字段保持原值；`auto_reject_above` 1–100 且必须大于 `auto_approve_below`，否则 400 `invalid_body`。`ai_enabled=false` 时只用规则分。
- `GET /admin/v1/moderation/estimate?auto_approve_below=20&auto_reject_above=90` → `{"per_day_manual": 46.3, "per_day_auto_approve": 812.1, "per_day_auto_reject": 9.4, "days": 7}`：按最近 7 天的风险分分布，估算设置为这两条线时每天人工量。（角色：admin；参数不传时用当前设置；拦截线不高于放行线 400 `invalid_body`）

### ReviewTask 新增字段（M-17）
```json
"ai": { "risk_score": 85, "labels": ["ad","contact"], "reason": "...", "confidence": 0.92, "suggestion": "reject", "model_name": "通义千问" },
"user_violation_count": 2,
"has_activity": true
```
`ai` 没有 AI 判定时为 `null`；`user_violation_count` 为作者历史被拒绝 / 下架次数；`has_activity` 表示动态附了运动（可以「隐藏起终点后通过」）。

### 新的处理动作（M-18）
`POST /admin/v1/reviews/{id}/decide`
```json
{ "action": "approve | approve_masked | approve_hide_endpoints | reject | reject_mute", "reason": "含广告", "mute_days": 7 }
```
- `approve_masked`（打码后通过）：文本里命中的敏感词和联系方式替换为 `*`，AI 标记的违规图片从动态里移除（图片类对象恢复默认头像），然后通过。
- `approve_hide_endpoints`（隐藏起终点后通过）：只对附了运动的动态；把这条动态的起终点隐藏半径设为 500 m 后通过。
- `reject_mute`：拒绝并禁言 `mute_days` 天（默认 7）。
- 返回 `{"task": ReviewTask, "next": ReviewTask | null}`：`task` 是处理后的任务，`next` 是下一条待审核任务（按风险分倒序、时间正序；`?target_type=` 可限定类型），管理端处理后自动跳到下一条。
- 错误：已审核过 409 `already_reviewed`；`action` 取值错误或 `mute_days` 不在 1–365 400 `invalid_body`；`approve_hide_endpoints` 用在没附运动的对象上、`approve_masked` 用在不支持的类型上 400 `not_supported`。记审计日志 `review.<action>`。
- 原有的 `/approve`、`/reject`、`/batch` 保留。

---

## 管理端 · AI 用量

### GET /admin/v1/ai/usage?days=7 → 
```json
{
  "days": [ { "date": "2026-11-20", "calls": 1234, "failed": 3, "prompt_tokens": 456000, "completion_tokens": 123000, "cost_fen": 812 } ],
  "by_feature": [ { "feature": "chat | route | report | moderation | workout", "calls": 900, "failed": 2, "avg_latency_ms": 1800, "prompt_tokens": 300000, "completion_tokens": 90000, "cost_fen": 600 } ],
  "quota": { "users_hit_limit_this_week": 120 }
}
```
（角色：admin、ops）`cost_fen` 按「AI 大模型」里填的单价估算，没填为 `null`（开发环境模拟 AI 的调用不计费）。`days` 按 Asia/Shanghai 日期、`?days=` 1–90（默认 7），没有调用的日期也列出；`by_feature` 固定列出 5 个功能。

### GET /admin/v1/ai/calls?feature=&status=ok|failed&page= → `{"items":[{"id","feature","user":{"id","nickname"},"model","status","error","prompt_tokens","completion_tokens","latency_ms","created_at"}],"total"}`
（只有元数据，不含对话内容；角色：admin、ops；超时的 `error` 为 `"timeout"`；`user` 没有时为 `null`）

### GET /admin/v1/users/{id}/ai-messages?page= → `{"items":[AIMessage],"total"}`（角色：admin；用于投诉核查；含用户已清空的消息；查看记审计日志 `ai.messages.view`）

---

## 玩法配置新增

```json
{
  "workouts": [ Workout ],
  "ai": { "route_max_km": 15, "report_max_chars": 120, "chat_history_turns": 6 }
}
```

玩法配置校验：`route_max_km` 0–100，`report_max_chars` 20–500，`chat_history_turns` 0–20；`workouts[].sport` 为 `rope`/`hiit`/`yoga`/`strength`，`steps[].mode` 为 `count`/`time`、`target>0`、`sets≥1`、`pose` 为上面的取值，`key` 不重复。

## 数据库（新增表）

| 表 | 说明 |
| --- | --- |
| `src.src_msg_loop_ai_message` | 助手对话（用户提问与 AI 回答、卡片、模型、Token） |
| `src.src_sys_loop_ai_call` | 每次模型调用的元数据（功能、用户、模型、状态、Token、耗时） |
| `src.src_act_loop_ai_report` | 运动的 AI 战报 |
| `src.src_cnt_loop_review_task` 增加 AI 判定字段 | `ai_score`、`ai_labels_json`、`ai_reason`、`ai_confidence_rate`、`ai_suggestion_type`、`ai_model` |
| `src.src_cnt_loop_review_task` 还增加 | `rule_score`、`ai_flagged_images_json`、`ai_status`（补打分状态）、`ai_retry_qty`、`decision_type`（manual / auto_approve / auto_reject）、`submit_type`（submit / report） |
| `src.src_soc_loop_post` 增加 | `ai_report_text`、`hide_endpoints_m` |
| `src.src_act_loop_activity` 增加 | `coach_json`（跟练上报） |

耗时字段用 `_ms`（毫秒），本批起加入命名规范的字段关键字。
