-- V2 第四批「本地生活与商户」A 部分：场馆、场馆签到、每周馆主、订场；订单按业务类型
-- 分发（会员 / 订场 / 赛事报名费）；赛事报名费。

-- ---------------------------------------------------------------- 场馆
CREATE TABLE src.src_mer_loop_venue (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id          BIGINT      REFERENCES src.src_mer_loop_merchant (id),
    venue_name           TEXT        NOT NULL,
    sports               TEXT[]      NOT NULL DEFAULT '{}',
    center_geom          GEOMETRY(Point, 4326) NOT NULL,
    address              TEXT        NOT NULL DEFAULT '',
    district             TEXT        NOT NULL DEFAULT '',
    tags                 TEXT[]      NOT NULL DEFAULT '{}',
    cover_url            TEXT,
    checkin_radius_m     DOUBLE PRECISION NOT NULL DEFAULT 150 CHECK (checkin_radius_m > 0 AND checkin_radius_m <= 2000),
    is_bookable          BOOLEAN     NOT NULL DEFAULT false,
    price_amt            INT         CHECK (price_amt > 0),
    slot_minutes         INT         NOT NULL DEFAULT 60 CHECK (slot_minutes BETWEEN 15 AND 240),
    open_time            TIME        NOT NULL DEFAULT '07:00',
    close_time           TIME        NOT NULL DEFAULT '23:00',
    court_qty            INT         NOT NULL DEFAULT 1 CHECK (court_qty BETWEEN 1 AND 100),
    owner_discount_rate  NUMERIC(4,3) CHECK (owner_discount_rate > 0 AND owner_discount_rate <= 1),
    qr_version           INT         NOT NULL DEFAULT 1,
    is_disabled          BOOLEAN     NOT NULL DEFAULT false,
    create_time          TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (close_time > open_time),
    CHECK (NOT is_bookable OR (merchant_id IS NOT NULL AND price_amt IS NOT NULL))
);
CREATE INDEX venue_center ON src.src_mer_loop_venue USING GIST (center_geom) WHERE NOT is_disabled;
CREATE INDEX venue_merchant ON src.src_mer_loop_venue (merchant_id);
COMMENT ON TABLE src.src_mer_loop_venue IS '场馆：合作场馆（可订场）和签到据点（运营录入，不可订场）';
COMMENT ON COLUMN src.src_mer_loop_venue.id IS '场馆ID';
COMMENT ON COLUMN src.src_mer_loop_venue.merchant_id IS '所属商户ID（src_mer_loop_merchant.id；非合作的签到据点为空）';
COMMENT ON COLUMN src.src_mer_loop_venue.venue_name IS '场馆名称';
COMMENT ON COLUMN src.src_mer_loop_venue.sports IS '运动分类（数组）：basketball-篮球 football-足球 badminton-羽毛球 pickleball-匹克球 tennis-网球 swimming-游泳 climbing-攀岩 gym-健身房';
COMMENT ON COLUMN src.src_mer_loop_venue.center_geom IS '场馆位置（GCJ-02）';
COMMENT ON COLUMN src.src_mer_loop_venue.address IS '地址';
COMMENT ON COLUMN src.src_mer_loop_venue.district IS '城区';
COMMENT ON COLUMN src.src_mer_loop_venue.tags IS '标签（数组，如 室内、可租拍）';
COMMENT ON COLUMN src.src_mer_loop_venue.cover_url IS '封面图地址';
COMMENT ON COLUMN src.src_mer_loop_venue.checkin_radius_m IS '定位签到半径（米）';
COMMENT ON COLUMN src.src_mer_loop_venue.is_bookable IS '是否开放订场（还要求商户为合作中、场馆未停用）';
COMMENT ON COLUMN src.src_mer_loop_venue.price_amt IS '订场价格（分/小时；一个时段的价格按时段长度折算）';
COMMENT ON COLUMN src.src_mer_loop_venue.slot_minutes IS '订场时段长度（分钟）';
COMMENT ON COLUMN src.src_mer_loop_venue.open_time IS '每天营业开始时间（Asia/Shanghai）';
COMMENT ON COLUMN src.src_mer_loop_venue.close_time IS '每天营业结束时间（Asia/Shanghai）';
COMMENT ON COLUMN src.src_mer_loop_venue.court_qty IS '可订场地数（同一时段最多同时订出的场地数）';
COMMENT ON COLUMN src.src_mer_loop_venue.owner_discount_rate IS '馆主订场折扣（0.8 表示八折；空表示无折扣）';
COMMENT ON COLUMN src.src_mer_loop_venue.qr_version IS '场馆二维码版本（换码时加 1，签名包含版本，旧码随之失效）';
COMMENT ON COLUMN src.src_mer_loop_venue.is_disabled IS '是否停用（停用后 App 不展示、不能签到和订场）';
COMMENT ON COLUMN src.src_mer_loop_venue.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_venue.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 场馆签到
CREATE TABLE src.src_mer_loop_venue_checkin (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id         BIGINT      NOT NULL REFERENCES src.src_mer_loop_venue (id) ON DELETE CASCADE,
    user_id          BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    checkin_date     DATE        NOT NULL,
    week_start_date  DATE        NOT NULL,
    checkin_type     TEXT        NOT NULL CHECK (checkin_type IN ('radius', 'qr')),
    activity_id      BIGINT      REFERENCES src.src_act_loop_activity (id) ON DELETE SET NULL,
    energy_qty       INT         NOT NULL DEFAULT 0,
    points_qty       INT         NOT NULL DEFAULT 0,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (venue_id, user_id, checkin_date)
);
CREATE INDEX venue_checkin_user ON src.src_mer_loop_venue_checkin (user_id, checkin_date);
CREATE INDEX venue_checkin_week ON src.src_mer_loop_venue_checkin (venue_id, week_start_date);
COMMENT ON TABLE src.src_mer_loop_venue_checkin IS '场馆签到（每人每个场馆每天 1 次；每次生成一条 venue 运动记录并加馆主积分）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.id IS '签到ID';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.venue_id IS '场馆ID（src_mer_loop_venue.id）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.user_id IS '签到用户ID（src_usr_loop_user.id）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.checkin_date IS '签到日期（Asia/Shanghai）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.week_start_date IS '签到所在周的周一（馆主积分按周累计）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.checkin_type IS '签到方式：radius-在场馆范围内定位签到 qr-扫场馆二维码签到';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.activity_id IS '签到生成的运动记录ID（src_act_loop_activity.id，sport=venue）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.energy_qty IS '本次实际获得的能量（计入每日上限后）';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.points_qty IS '本次获得的馆主积分';
COMMENT ON COLUMN src.src_mer_loop_venue_checkin.create_time IS '签到时间';

-- ---------------------------------------------------------------- 每周馆主
CREATE TABLE src.src_mer_loop_venue_owner (
    venue_id         BIGINT      NOT NULL REFERENCES src.src_mer_loop_venue (id) ON DELETE CASCADE,
    week_start_date  DATE        NOT NULL,
    user_id          BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    points_qty       INT         NOT NULL,
    reach_time       TIMESTAMPTZ NOT NULL,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (venue_id, week_start_date)
);
CREATE INDEX venue_owner_user ON src.src_mer_loop_venue_owner (user_id);
COMMENT ON TABLE src.src_mer_loop_venue_owner IS '每周馆主：每周一 00:00（Asia/Shanghai）按上周签到积分第一确定本周馆主（同分先达到者胜）';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.venue_id IS '场馆ID（src_mer_loop_venue.id）';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.week_start_date IS '任期所在周的周一（本周馆主）';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.user_id IS '馆主用户ID（src_usr_loop_user.id）';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.points_qty IS '上周获得的馆主积分';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.reach_time IS '达到该积分的时间（同分时先达到者胜）';
COMMENT ON COLUMN src.src_mer_loop_venue_owner.create_time IS '结算时间';

-- ---------------------------------------------------------------- 订单按业务类型
ALTER TABLE src.src_ord_loop_order
    ADD COLUMN biz_type TEXT NOT NULL DEFAULT 'membership' CHECK (biz_type IN ('membership', 'booking', 'race_fee')),
    ADD COLUMN biz_id   BIGINT;
ALTER TABLE src.src_ord_loop_order ALTER COLUMN plan_code DROP NOT NULL;
ALTER TABLE src.src_ord_loop_order ADD CONSTRAINT order_biz_ref CHECK (
    (biz_type = 'membership' AND plan_code IS NOT NULL) OR (biz_type <> 'membership' AND plan_code IS NULL AND biz_id IS NOT NULL));
CREATE INDEX orders_biz ON src.src_ord_loop_order (biz_type, biz_id) WHERE biz_type <> 'membership';
COMMENT ON TABLE src.src_ord_loop_order IS '订单：会员、订场、赛事报名费（支付回调和退款按 biz_type 分发）';
COMMENT ON COLUMN src.src_ord_loop_order.biz_type IS '业务类型：membership-会员 booking-订场 race_fee-赛事报名费';
COMMENT ON COLUMN src.src_ord_loop_order.biz_id IS '业务ID：booking 为 src_ord_loop_booking.id，race_fee 为 src_mkt_loop_race.id（报名人即下单用户）；会员订单为空';
COMMENT ON COLUMN src.src_ord_loop_order.plan_code IS '套餐代码（src_ord_loop_plan.code；非会员订单为空）';
COMMENT ON COLUMN src.src_ord_loop_order.plan_name IS '订单标题：会员为下单时的套餐名称，订场 / 报名费为商品说明';

-- ---------------------------------------------------------------- 订场
CREATE TABLE src.src_ord_loop_booking (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_no      TEXT        NOT NULL UNIQUE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    venue_id        BIGINT      NOT NULL REFERENCES src.src_mer_loop_venue (id),
    merchant_id     BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    start_time      TIMESTAMPTZ NOT NULL,
    end_time        TIMESTAMPTZ NOT NULL,
    slot_qty        INT         NOT NULL CHECK (slot_qty > 0),
    court_qty       INT         NOT NULL DEFAULT 1 CHECK (court_qty > 0),
    amount_amt      INT         NOT NULL CHECK (amount_amt > 0),
    original_amt    INT         NOT NULL CHECK (original_amt > 0),
    discount_type   TEXT        NOT NULL DEFAULT 'none' CHECK (discount_type IN ('owner', 'none')),
    booking_status  TEXT        NOT NULL DEFAULT 'pending_pay'
                    CHECK (booking_status IN ('pending_pay', 'paid', 'cancelled', 'refunding', 'refunded', 'completed', 'expired')),
    meetup_id       BIGINT      REFERENCES src.src_soc_loop_meetup (id) ON DELETE SET NULL,
    order_no        TEXT        REFERENCES src.src_ord_loop_order (order_no),
    channel         TEXT        NOT NULL,
    paid_time       TIMESTAMPTZ,
    refund_time     TIMESTAMPTZ,
    refund_reason   TEXT,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
CREATE INDEX booking_venue_time ON src.src_ord_loop_booking (venue_id, start_time) WHERE booking_status IN ('pending_pay', 'paid', 'completed');
CREATE INDEX booking_user ON src.src_ord_loop_booking (user_id, create_time DESC);
CREATE INDEX booking_merchant ON src.src_ord_loop_booking (merchant_id, start_time);
CREATE INDEX booking_meetup ON src.src_ord_loop_booking (meetup_id) WHERE meetup_id IS NOT NULL;
CREATE UNIQUE INDEX booking_order ON src.src_ord_loop_booking (order_no) WHERE order_no IS NOT NULL;
COMMENT ON TABLE src.src_ord_loop_booking IS '订场：合作场馆的连续时段，微信 / 支付宝支付（iOS 同样，线下服务不走内购）';
COMMENT ON COLUMN src.src_ord_loop_booking.id IS '订场ID';
COMMENT ON COLUMN src.src_ord_loop_booking.booking_no IS '订场编号（BK + 时间 + 随机数）';
COMMENT ON COLUMN src.src_ord_loop_booking.user_id IS '下单用户ID（src_usr_loop_user.id）';
COMMENT ON COLUMN src.src_ord_loop_booking.venue_id IS '场馆ID（src_mer_loop_venue.id）';
COMMENT ON COLUMN src.src_ord_loop_booking.merchant_id IS '场馆所属商户ID（src_mer_loop_merchant.id，结算用）';
COMMENT ON COLUMN src.src_ord_loop_booking.start_time IS '开始时间（第一个时段的开始）';
COMMENT ON COLUMN src.src_ord_loop_booking.end_time IS '结束时间（最后一个时段的结束）';
COMMENT ON COLUMN src.src_ord_loop_booking.slot_qty IS '连续时段数（1–玩法配置 booking.max_slots）';
COMMENT ON COLUMN src.src_ord_loop_booking.court_qty IS '场地数';
COMMENT ON COLUMN src.src_ord_loop_booking.amount_amt IS '实付金额（分，馆主折扣后）';
COMMENT ON COLUMN src.src_ord_loop_booking.original_amt IS '原价（分）';
COMMENT ON COLUMN src.src_ord_loop_booking.discount_type IS '优惠类型：owner-馆主折扣 none-无优惠';
COMMENT ON COLUMN src.src_ord_loop_booking.booking_status IS '订场状态：pending_pay-待支付（超时自动 expired） paid-已支付 cancelled-未支付取消 refunding-退款中 refunded-已退款 completed-已完成（开始时间已过） expired-支付超时';
COMMENT ON COLUMN src.src_ord_loop_booking.meetup_id IS '关联的约球组局ID（src_soc_loop_meetup.id，组局发起人订场时填写）';
COMMENT ON COLUMN src.src_ord_loop_booking.order_no IS '支付订单号（src_ord_loop_order.order_no，biz_type=booking）';
COMMENT ON COLUMN src.src_ord_loop_booking.channel IS '支付渠道：wechat_app-微信 alipay_app-支付宝 mock-开发环境模拟';
COMMENT ON COLUMN src.src_ord_loop_booking.paid_time IS '支付时间';
COMMENT ON COLUMN src.src_ord_loop_booking.refund_time IS '退款完成时间';
COMMENT ON COLUMN src.src_ord_loop_booking.refund_reason IS '退款原因（用户取消或管理端退款说明）';
COMMENT ON COLUMN src.src_ord_loop_booking.create_time IS '下单时间';
COMMENT ON COLUMN src.src_ord_loop_booking.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 赛事报名费
ALTER TABLE src.src_mkt_loop_race ADD COLUMN fee_amt INT NOT NULL DEFAULT 0 CHECK (fee_amt >= 0);
COMMENT ON COLUMN src.src_mkt_loop_race.fee_amt IS '报名费（分；0 表示免费）';
ALTER TABLE src.src_mkt_loop_race_entry DROP CONSTRAINT src_mkt_loop_race_entry_entry_status_check;
ALTER TABLE src.src_mkt_loop_race_entry ADD CONSTRAINT src_mkt_loop_race_entry_entry_status_check
    CHECK (entry_status IN ('pending_pay', 'signed', 'finished'));
ALTER TABLE src.src_mkt_loop_race_entry ADD COLUMN order_no TEXT REFERENCES src.src_ord_loop_order (order_no);
COMMENT ON COLUMN src.src_mkt_loop_race_entry.entry_status IS '报名状态：pending_pay-待支付报名费（超时未支付即删除） signed-已报名 finished-已完赛（赛事结束仍为 signed 的，接口显示为 dnf-未完赛）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.order_no IS '报名费订单号（src_ord_loop_order.order_no，biz_type=race_fee；免费赛事为空）';
COMMENT ON TABLE src.src_mkt_loop_race_entry IS '赛事报名与成绩（开始前取消报名即删除，已付报名费原路退款）';
