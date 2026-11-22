-- V2 第五批「商户商品与开放平台」B 部分：开放平台应用、调用日志、Webhook 事件与投递、
-- 外部占场（docs/api/v2-5-商户商品与开放平台.md «开放平台»）。

-- ---------------------------------------------------------------- 开放平台应用
CREATE TABLE src.src_mer_loop_open_app (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    app_code         TEXT        NOT NULL UNIQUE,
    merchant_id      BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    app_name         TEXT        NOT NULL,
    scopes           TEXT[]      NOT NULL DEFAULT '{}',
    ip_allowlist     TEXT[]      NOT NULL DEFAULT '{}',
    webhook_url      TEXT,
    webhook_events   TEXT[]      NOT NULL DEFAULT '{}',
    app_secret_enc   BYTEA       NOT NULL,
    app_status       TEXT        NOT NULL DEFAULT 'active' CHECK (app_status IN ('active', 'disabled')),
    disable_type     TEXT        CHECK (disable_type IN ('merchant', 'platform')),
    last_use_time    TIMESTAMPTZ,
    create_admin_id  BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX open_app_merchant ON src.src_mer_loop_open_app (merchant_id);
COMMENT ON TABLE src.src_mer_loop_open_app IS '开放平台应用：商户的接口凭证（每个商户最多 5 个），外部系统用签名调用 /open/v1，平台向 webhook_url 推送事件';
COMMENT ON COLUMN src.src_mer_loop_open_app.id IS '应用ID';
COMMENT ON COLUMN src.src_mer_loop_open_app.app_code IS '对外的应用标识 app_id（lpa_ + 8 位随机串，请求头 X-Loop-App-Id）';
COMMENT ON COLUMN src.src_mer_loop_open_app.merchant_id IS '所属商户ID（接口只能操作本商户的数据）';
COMMENT ON COLUMN src.src_mer_loop_open_app.app_name IS '应用名称（如「收银系统」）';
COMMENT ON COLUMN src.src_mer_loop_open_app.scopes IS '授权范围：products-商品 orders-商品订单 bookings-订场 redemptions-核销 statements-结算单 venues-场馆与占场 promotions-官方活动';
COMMENT ON COLUMN src.src_mer_loop_open_app.ip_allowlist IS '调用方 IP 白名单（空为不限）';
COMMENT ON COLUMN src.src_mer_loop_open_app.webhook_url IS 'Webhook 推送地址（空为不推送）';
COMMENT ON COLUMN src.src_mer_loop_open_app.webhook_events IS '订阅的事件类型（如 product_order.paid、redemption.created）；还要求应用有对应 scope';
COMMENT ON COLUMN src.src_mer_loop_open_app.app_secret_enc IS '应用密钥（AES-256-GCM 加密，数据加密密钥；只在创建和重置时返回一次明文）';
COMMENT ON COLUMN src.src_mer_loop_open_app.app_status IS '应用状态：active-启用 disabled-停用（接口返回 403 app_disabled，Webhook 停发）';
COMMENT ON COLUMN src.src_mer_loop_open_app.disable_type IS '停用方：merchant-商户自己停用 platform-平台停用（商户不能自行启用）；启用时为空';
COMMENT ON COLUMN src.src_mer_loop_open_app.last_use_time IS '最近一次调用时间';
COMMENT ON COLUMN src.src_mer_loop_open_app.create_admin_id IS '创建人（后台商户账号ID）';
COMMENT ON COLUMN src.src_mer_loop_open_app.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_open_app.update_time IS '最后修改时间';

CREATE TABLE src.src_mer_loop_open_call_log (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    open_app_id   BIGINT      NOT NULL REFERENCES src.src_mer_loop_open_app (id) ON DELETE CASCADE,
    http_method   TEXT        NOT NULL,
    request_path  TEXT        NOT NULL,
    status_code   INT         NOT NULL,
    error_code    TEXT,
    latency_ms    INT         NOT NULL DEFAULT 0,
    client_ip     TEXT        NOT NULL DEFAULT '',
    create_time   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX open_call_log_app ON src.src_mer_loop_open_call_log (open_app_id, id DESC);
CREATE INDEX open_call_log_time ON src.src_mer_loop_open_call_log (create_time);
COMMENT ON TABLE src.src_mer_loop_open_call_log IS '开放接口调用日志（保留 7 天，不记请求体）';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.id IS '调用记录ID';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.open_app_id IS '应用ID';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.http_method IS '请求方法（GET / POST / PATCH / PUT / DELETE）';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.request_path IS '请求路径（不含 query）';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.status_code IS 'HTTP 状态码';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.error_code IS '错误码（成功为空）';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.latency_ms IS '耗时（毫秒）';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.client_ip IS '调用方 IP';
COMMENT ON COLUMN src.src_mer_loop_open_call_log.create_time IS '调用时间';

-- ---------------------------------------------------------------- Webhook
CREATE TABLE src.src_mer_loop_webhook_event (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_no      TEXT        NOT NULL UNIQUE,
    merchant_id   BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    event_type    TEXT        NOT NULL,
    payload_json  JSONB       NOT NULL,
    create_time   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX webhook_event_merchant ON src.src_mer_loop_webhook_event (merchant_id, id DESC);
COMMENT ON TABLE src.src_mer_loop_webhook_event IS 'Webhook 事件：平台推给商户系统的业务事件（只在有应用订阅时记录）';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.id IS '事件ID';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.event_no IS '对外事件标识（evt_ 开头，接收方按它去重）';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.event_type IS '事件类型：product.reviewed-商品审核结果 promotion_entry.invited-平台邀请商品参加活动 promotion_entry.approved-活动条目生效 promotion_entry.rejected-活动条目被拒 promotion_entry.removed-平台移除条目 product_order.paid-商品订单支付 product_order.refunded-商品订单退款 booking.paid-订场支付 booking.cancelled-订场取消 booking.refunded-订场退款 redemption.created-核销 redemption.voided-核销作废 statement.created-结算单生成 ping-测试';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.payload_json IS '推送的请求体（id、type、created_at、merchant_id、data）';
COMMENT ON COLUMN src.src_mer_loop_webhook_event.create_time IS '事件时间';

CREATE TABLE src.src_mer_loop_webhook_delivery (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id           BIGINT      NOT NULL REFERENCES src.src_mer_loop_webhook_event (id) ON DELETE CASCADE,
    open_app_id        BIGINT      NOT NULL REFERENCES src.src_mer_loop_open_app (id) ON DELETE CASCADE,
    delivery_status    TEXT        NOT NULL DEFAULT 'pending' CHECK (delivery_status IN ('pending', 'succeeded', 'failed')),
    attempt_qty        INT         NOT NULL DEFAULT 0,
    last_status_code   INT,
    last_error         TEXT,
    next_retry_time    TIMESTAMPTZ,
    last_attempt_time  TIMESTAMPTZ,
    create_time        TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX webhook_delivery_due ON src.src_mer_loop_webhook_delivery (next_retry_time) WHERE delivery_status = 'pending';
CREATE INDEX webhook_delivery_app ON src.src_mer_loop_webhook_delivery (open_app_id, id DESC);
COMMENT ON TABLE src.src_mer_loop_webhook_delivery IS 'Webhook 投递：一个事件推给一个应用；10 秒内 2xx 算成功，否则按 1 分钟、5 分钟、30 分钟、2 小时、6 小时重试，共 6 次';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.id IS '投递ID（请求头 X-Loop-Delivery）';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.event_id IS '事件ID';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.open_app_id IS '应用ID';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.delivery_status IS '投递状态：pending-待投递 / 等待重试 succeeded-成功 failed-失败（6 次都没成功或应用已停用；可在管理端手动重发）';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.attempt_qty IS '已尝试次数';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.last_status_code IS '最近一次对方返回的 HTTP 状态码（连接失败为空）';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.last_error IS '最近一次失败原因';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.next_retry_time IS '下次投递时间（pending 时有值）';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.last_attempt_time IS '最近一次投递时间';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_webhook_delivery.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 外部占场
CREATE TABLE src.src_mer_loop_venue_block (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id      BIGINT      NOT NULL REFERENCES src.src_mer_loop_venue (id) ON DELETE CASCADE,
    merchant_id   BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    open_app_id   BIGINT      REFERENCES src.src_mer_loop_open_app (id) ON DELETE SET NULL,
    block_date    DATE        NOT NULL,
    start_time    TIMESTAMPTZ NOT NULL,
    end_time      TIMESTAMPTZ NOT NULL,
    court_qty     INT         NOT NULL DEFAULT 1 CHECK (court_qty BETWEEN 1 AND 100),
    external_ref  TEXT,
    note          TEXT        NOT NULL DEFAULT '',
    create_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
CREATE INDEX venue_block_time ON src.src_mer_loop_venue_block (venue_id, start_time);
CREATE UNIQUE INDEX venue_block_ref ON src.src_mer_loop_venue_block (venue_id, external_ref) WHERE external_ref IS NOT NULL;
COMMENT ON TABLE src.src_mer_loop_venue_block IS '外部占场：商户在自有系统卖掉的场地同步过来，占用对应时段的场地数（App 上这些时段不可订）';
COMMENT ON COLUMN src.src_mer_loop_venue_block.id IS '占场ID';
COMMENT ON COLUMN src.src_mer_loop_venue_block.venue_id IS '场馆ID';
COMMENT ON COLUMN src.src_mer_loop_venue_block.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_mer_loop_venue_block.open_app_id IS '同步过来的开放平台应用ID';
COMMENT ON COLUMN src.src_mer_loop_venue_block.block_date IS '占场日期（Asia/Shanghai）';
COMMENT ON COLUMN src.src_mer_loop_venue_block.start_time IS '开始时间（对齐场馆时段）';
COMMENT ON COLUMN src.src_mer_loop_venue_block.end_time IS '结束时间（对齐场馆时段）';
COMMENT ON COLUMN src.src_mer_loop_venue_block.court_qty IS '占用场地数';
COMMENT ON COLUMN src.src_mer_loop_venue_block.external_ref IS '外部单号（同一场馆重复提交同一单号返回已有的占场）';
COMMENT ON COLUMN src.src_mer_loop_venue_block.note IS '备注';
COMMENT ON COLUMN src.src_mer_loop_venue_block.create_time IS '创建时间';
