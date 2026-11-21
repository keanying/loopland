-- V2 第四批「本地生活与商户」part B：投放、券、核销、联名活动、结算、能量商城
-- （docs/api/v2-4-本地生活与商户.md）。场馆、订场在 0009，这里只按 ID 引用，不建外键。

-- ---------------------------------------------------------------- 联名活动
CREATE TABLE src.src_mkt_loop_brand_campaign (
    id                       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id              BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    campaign_title           TEXT        NOT NULL,
    description              TEXT        NOT NULL DEFAULT '',
    cover_url                TEXT,
    start_time               TIMESTAMPTZ NOT NULL,
    end_time                 TIMESTAMPTZ NOT NULL,
    campaign_status          TEXT        NOT NULL DEFAULT 'published' CHECK (campaign_status IN ('draft', 'published', 'paused')),
    store_qty                INT         NOT NULL DEFAULT 0 CHECK (store_qty >= 0),
    target_redemption_qty    INT         NOT NULL DEFAULT 0 CHECK (target_redemption_qty >= 0),
    merchant_investment_amt  BIGINT      NOT NULL DEFAULT 0 CHECK (merchant_investment_amt >= 0),
    create_admin_id          BIGINT,
    create_time              TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time              TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
CREATE INDEX brand_campaign_merchant ON src.src_mkt_loop_brand_campaign (merchant_id);
COMMENT ON TABLE src.src_mkt_loop_brand_campaign IS '联名活动：商户出资的品牌活动，下挂若干投放点';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.id IS '联名活动ID';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.merchant_id IS '出资商户ID';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.campaign_title IS '活动标题';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.description IS '活动说明（App 展示规则和领取方式）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.cover_url IS '封面图地址';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.start_time IS '开始时间（提前上线时改为上线那一刻）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.end_time IS '结束时间';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.campaign_status IS '活动状态：draft-草稿（不对外、投放不发券） published-已发布（按时间显示为 scheduled 未开始 / running 进行中 / ended 已结束） paused-已暂停（其下所有投放一并暂停）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.store_qty IS '参与门店数';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.target_redemption_qty IS '目标核销张数（进度 = 已核销 / 目标）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.merchant_investment_amt IS '商户投入金额（分）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.create_admin_id IS '创建人（后台账号ID）';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mkt_loop_brand_campaign.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 投放
CREATE TABLE src.src_mer_loop_drop (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id         BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    campaign_id         BIGINT      REFERENCES src.src_mkt_loop_brand_campaign (id) ON DELETE SET NULL,
    drop_type           TEXT        NOT NULL CHECK (drop_type IN ('supply', 'chest', 'stronghold')),
    drop_name           TEXT        NOT NULL,
    center_geom         geometry(Point, 4326),
    radius_m            DOUBLE PRECISION NOT NULL DEFAULT 80 CHECK (radius_m > 0),
    venue_id            BIGINT,
    store_name          TEXT,
    perk_title          TEXT        NOT NULL,
    perk_description    TEXT        NOT NULL DEFAULT '',
    perk_value_text     TEXT        NOT NULL DEFAULT '',
    perk_valid_days     INT         NOT NULL DEFAULT 7 CHECK (perk_valid_days BETWEEN 1 AND 365),
    perk_rules          TEXT        NOT NULL DEFAULT '',
    daily_cap_qty       INT         NOT NULL DEFAULT 0 CHECK (daily_cap_qty >= 0),
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    is_paused           BOOLEAN     NOT NULL DEFAULT false,
    settle_price_amt    BIGINT      NOT NULL DEFAULT 0 CHECK (settle_price_amt >= 0),
    settle_direction    TEXT        NOT NULL DEFAULT 'merchant_pays' CHECK (settle_direction IN ('merchant_pays', 'platform_pays')),
    create_admin_id     BIGINT,
    create_time         TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time),
    CHECK (drop_type = 'stronghold' OR center_geom IS NOT NULL),
    CHECK (drop_type <> 'stronghold' OR venue_id IS NOT NULL)
);
CREATE INDEX drop_center ON src.src_mer_loop_drop USING GIST (center_geom);
CREATE INDEX drop_merchant ON src.src_mer_loop_drop (merchant_id);
CREATE INDEX drop_campaign ON src.src_mer_loop_drop (campaign_id);
CREATE INDEX drop_venue ON src.src_mer_loop_drop (venue_id) WHERE venue_id IS NOT NULL;
COMMENT ON TABLE src.src_mer_loop_drop IS '投放：补给站 / 商户宝箱 / 据点，按运动或签到免费发券（不设付费抽取）';
COMMENT ON COLUMN src.src_mer_loop_drop.id IS '投放ID';
COMMENT ON COLUMN src.src_mer_loop_drop.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_mer_loop_drop.campaign_id IS '所属联名活动ID（可空；活动暂停 / 未开始 / 结束时投放跟随）';
COMMENT ON COLUMN src.src_mer_loop_drop.drop_type IS '投放类型：supply-补给站（运动轨迹经过或人在范围内领取） chest-商户宝箱（在投放位置刷宝箱，开箱得券） stronghold-据点（绑定场馆，签到得券）';
COMMENT ON COLUMN src.src_mer_loop_drop.drop_name IS '投放名称（如「补给站 · 瑞幸滨江店」）';
COMMENT ON COLUMN src.src_mer_loop_drop.center_geom IS '投放位置（GCJ-02，SRID 4326；据点可空，取场馆位置）';
COMMENT ON COLUMN src.src_mer_loop_drop.radius_m IS '范围半径（米）：轨迹经过 / 人在范围内可领取，宝箱的开启半径';
COMMENT ON COLUMN src.src_mer_loop_drop.venue_id IS '绑定场馆ID（据点必填，对应 src.src_mer_loop_venue.id）';
COMMENT ON COLUMN src.src_mer_loop_drop.store_name IS '核销门店名（核销记录默认取它，空时取投放名称）';
COMMENT ON COLUMN src.src_mer_loop_drop.perk_title IS '权益标题（如「美式咖啡 5 折」）';
COMMENT ON COLUMN src.src_mer_loop_drop.perk_description IS '权益说明';
COMMENT ON COLUMN src.src_mer_loop_drop.perk_value_text IS '权益面值文案（如「5 折」）';
COMMENT ON COLUMN src.src_mer_loop_drop.perk_valid_days IS '券有效天数（从领取起算）';
COMMENT ON COLUMN src.src_mer_loop_drop.perk_rules IS '使用规则（App 内明示）';
COMMENT ON COLUMN src.src_mer_loop_drop.daily_cap_qty IS '每日上限：每天最多发出的券数，也是每天最多核销的张数（0 表示不限）';
COMMENT ON COLUMN src.src_mer_loop_drop.start_time IS '投放开始时间';
COMMENT ON COLUMN src.src_mer_loop_drop.end_time IS '投放结束时间';
COMMENT ON COLUMN src.src_mer_loop_drop.is_paused IS '是否手动暂停（状态 = 暂停 / 按时间未开始、进行中、已结束）';
COMMENT ON COLUMN src.src_mer_loop_drop.settle_price_amt IS '每张有效核销的结算单价（分）';
COMMENT ON COLUMN src.src_mer_loop_drop.settle_direction IS '结算方向：merchant_pays-商户付给平台的服务费 platform_pays-平台付给商户的补贴';
COMMENT ON COLUMN src.src_mer_loop_drop.create_admin_id IS '创建人（后台账号ID）';
COMMENT ON COLUMN src.src_mer_loop_drop.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_drop.update_time IS '最后修改时间';

-- 商户宝箱：沿用第一批宝箱，奖励改为券
ALTER TABLE src.src_ply_loop_chest ADD COLUMN drop_id BIGINT REFERENCES src.src_mer_loop_drop (id) ON DELETE SET NULL;
CREATE INDEX chest_drop ON src.src_ply_loop_chest (drop_id) WHERE drop_id IS NOT NULL;
COMMENT ON COLUMN src.src_ply_loop_chest.source IS '来源：system-系统每日刷新 admin-运营投放 merchant-商户宝箱投放（每天在投放位置刷一个，深夜不刷）';
COMMENT ON COLUMN src.src_ply_loop_chest.drop_id IS '商户宝箱对应的投放ID（有值时开箱得券、不给能量；空为普通能量宝箱）';

-- ---------------------------------------------------------------- 券
CREATE TABLE src.src_mkt_loop_coupon (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    coupon_code     TEXT        NOT NULL UNIQUE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    drop_id         BIGINT      NOT NULL REFERENCES src.src_mer_loop_drop (id),
    merchant_id     BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    campaign_id     BIGINT,
    source_type     TEXT        NOT NULL CHECK (source_type IN ('supply', 'chest', 'stronghold')),
    source_name     TEXT        NOT NULL,
    perk_json       JSONB       NOT NULL,
    coupon_status   TEXT        NOT NULL DEFAULT 'unused' CHECK (coupon_status IN ('unused', 'used', 'expired', 'voided')),
    obtain_date     DATE        NOT NULL,
    expire_time     TIMESTAMPTZ NOT NULL,
    use_time        TIMESTAMPTZ,
    use_store_name  TEXT,
    activity_id     BIGINT,
    chest_id        BIGINT,
    venue_id        BIGINT,
    void_time       TIMESTAMPTZ,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (drop_id, user_id, obtain_date)
);
CREATE INDEX coupon_user ON src.src_mkt_loop_coupon (user_id, create_time DESC);
CREATE INDEX coupon_drop_day ON src.src_mkt_loop_coupon (drop_id, obtain_date);
CREATE INDEX coupon_activity ON src.src_mkt_loop_coupon (activity_id) WHERE activity_id IS NOT NULL;
CREATE INDEX coupon_campaign ON src.src_mkt_loop_coupon (campaign_id) WHERE campaign_id IS NOT NULL;
CREATE INDEX coupon_unused_expire ON src.src_mkt_loop_coupon (expire_time) WHERE coupon_status = 'unused';
COMMENT ON TABLE src.src_mkt_loop_coupon IS '用户的券（卡券包）：每人每个投放每天最多 1 张';
COMMENT ON COLUMN src.src_mkt_loop_coupon.id IS '券ID';
COMMENT ON COLUMN src.src_mkt_loop_coupon.coupon_code IS '券码（8 位，店员可手输核销）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.user_id IS '持有用户ID';
COMMENT ON COLUMN src.src_mkt_loop_coupon.drop_id IS '来源投放ID';
COMMENT ON COLUMN src.src_mkt_loop_coupon.merchant_id IS '商户ID（核销时校验）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.campaign_id IS '来源联名活动ID（领取时投放所属的活动，用于活动统计）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.source_type IS '来源类型：supply-补给站 chest-商户宝箱 stronghold-据点签到';
COMMENT ON COLUMN src.src_mkt_loop_coupon.source_name IS '来源名称（领取时的投放名称）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.perk_json IS '领取时的权益快照（标题、说明、面值、有效天数、规则）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.coupon_status IS '券状态：unused-未使用 used-已核销 expired-已过期 voided-已作废（发券的运动记录被风控作废）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.obtain_date IS '领取日期（Asia/Shanghai，每人每个投放每天 1 张）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_mkt_loop_coupon.use_time IS '核销时间';
COMMENT ON COLUMN src.src_mkt_loop_coupon.use_store_name IS '核销门店';
COMMENT ON COLUMN src.src_mkt_loop_coupon.activity_id IS '发券的运动记录ID（经过补给站、轨迹开宝箱时有值）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.chest_id IS '开出这张券的宝箱ID';
COMMENT ON COLUMN src.src_mkt_loop_coupon.venue_id IS '据点签到的场馆ID';
COMMENT ON COLUMN src.src_mkt_loop_coupon.void_time IS '作废时间';
COMMENT ON COLUMN src.src_mkt_loop_coupon.create_time IS '领取时间';
COMMENT ON COLUMN src.src_mkt_loop_coupon.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 核销
CREATE TABLE src.src_mer_loop_redemption (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    redemption_no       TEXT        NOT NULL UNIQUE,
    coupon_id           BIGINT      NOT NULL UNIQUE REFERENCES src.src_mkt_loop_coupon (id),
    user_id             BIGINT      NOT NULL,
    merchant_id         BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    drop_id             BIGINT      NOT NULL REFERENCES src.src_mer_loop_drop (id),
    campaign_id         BIGINT,
    admin_id            BIGINT      NOT NULL,
    input_type          TEXT        NOT NULL CHECK (input_type IN ('payload', 'code')),
    store_name          TEXT        NOT NULL,
    activity_id         BIGINT      NOT NULL,
    redeem_date         DATE        NOT NULL,
    settle_price_amt    BIGINT      NOT NULL DEFAULT 0,
    settle_direction    TEXT        NOT NULL CHECK (settle_direction IN ('merchant_pays', 'platform_pays')),
    redemption_status   TEXT        NOT NULL DEFAULT 'valid' CHECK (redemption_status IN ('valid', 'voided')),
    void_reason         TEXT,
    void_time           TIMESTAMPTZ,
    statement_id        BIGINT,
    create_time         TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX redemption_merchant_day ON src.src_mer_loop_redemption (merchant_id, redeem_date);
CREATE INDEX redemption_drop_day ON src.src_mer_loop_redemption (drop_id, redeem_date);
CREATE INDEX redemption_activity ON src.src_mer_loop_redemption (activity_id);
COMMENT ON TABLE src.src_mer_loop_redemption IS '核销记录：店员扫码 / 手输券码核销，需要用户当天有一条有效运动记录';
COMMENT ON COLUMN src.src_mer_loop_redemption.id IS '核销ID';
COMMENT ON COLUMN src.src_mer_loop_redemption.redemption_no IS '核销流水号（结算单明细的单号）';
COMMENT ON COLUMN src.src_mer_loop_redemption.coupon_id IS '核销的券ID';
COMMENT ON COLUMN src.src_mer_loop_redemption.user_id IS '券持有用户ID';
COMMENT ON COLUMN src.src_mer_loop_redemption.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_mer_loop_redemption.drop_id IS '券来源投放ID（每日核销上限按它算）';
COMMENT ON COLUMN src.src_mer_loop_redemption.campaign_id IS '券来源联名活动ID';
COMMENT ON COLUMN src.src_mer_loop_redemption.admin_id IS '操作核销的后台账号ID（商户员工或运营）';
COMMENT ON COLUMN src.src_mer_loop_redemption.input_type IS '核销方式：payload-扫二维码（60 秒有效） code-手输券码';
COMMENT ON COLUMN src.src_mer_loop_redemption.store_name IS '核销门店';
COMMENT ON COLUMN src.src_mer_loop_redemption.activity_id IS '核销所依赖的当天运动记录ID（被风控作废且当天没有其他有效记录时，核销作废）';
COMMENT ON COLUMN src.src_mer_loop_redemption.redeem_date IS '核销日期（Asia/Shanghai）';
COMMENT ON COLUMN src.src_mer_loop_redemption.settle_price_amt IS '结算单价快照（分，取自投放）';
COMMENT ON COLUMN src.src_mer_loop_redemption.settle_direction IS '结算方向快照：merchant_pays-商户付给平台 platform_pays-平台付给商户';
COMMENT ON COLUMN src.src_mer_loop_redemption.redemption_status IS '核销状态：valid-有效（进结算） voided-已作废（依赖的运动记录被风控作废，不进结算）';
COMMENT ON COLUMN src.src_mer_loop_redemption.void_reason IS '作废原因：activity_voided-当天运动记录被作废';
COMMENT ON COLUMN src.src_mer_loop_redemption.void_time IS '作废时间';
COMMENT ON COLUMN src.src_mer_loop_redemption.statement_id IS '计入的结算单ID（生成结算单时写入）';
COMMENT ON COLUMN src.src_mer_loop_redemption.create_time IS '核销时间';
COMMENT ON COLUMN src.src_mer_loop_redemption.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 结算
CREATE TABLE src.src_fin_loop_statement (
    id                       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    statement_no             TEXT        NOT NULL UNIQUE,
    merchant_id              BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    period_start_date        DATE        NOT NULL,
    period_end_date          DATE        NOT NULL,
    redemption_qty           INT         NOT NULL DEFAULT 0,
    voided_qty               INT         NOT NULL DEFAULT 0,
    redemption_amt           BIGINT      NOT NULL DEFAULT 0,
    redemption_direction     TEXT        NOT NULL DEFAULT 'merchant_pays' CHECK (redemption_direction IN ('merchant_pays', 'platform_pays')),
    booking_qty              INT         NOT NULL DEFAULT 0,
    booking_amt              BIGINT      NOT NULL DEFAULT 0,
    booking_commission_rate  NUMERIC(5,4) NOT NULL DEFAULT 0,
    booking_commission_amt   BIGINT      NOT NULL DEFAULT 0,
    net_amt                  BIGINT      NOT NULL DEFAULT 0,
    statement_status         TEXT        NOT NULL DEFAULT 'draft' CHECK (statement_status IN ('draft', 'confirmed', 'paid')),
    confirm_admin_id         BIGINT,
    confirm_time             TIMESTAMPTZ,
    pay_time                 TIMESTAMPTZ,
    create_time              TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time              TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (merchant_id, period_start_date)
);
CREATE INDEX statement_status ON src.src_fin_loop_statement (statement_status);
COMMENT ON TABLE src.src_fin_loop_statement IS '结算单：每商户每周一张（周一 03:00 生成上周的），含核销和订场';
COMMENT ON COLUMN src.src_fin_loop_statement.id IS '结算单ID';
COMMENT ON COLUMN src.src_fin_loop_statement.statement_no IS '结算单号（ST<ISO 年>W<周>-<商户ID>）';
COMMENT ON COLUMN src.src_fin_loop_statement.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_fin_loop_statement.period_start_date IS '结算周期开始日期（周一）';
COMMENT ON COLUMN src.src_fin_loop_statement.period_end_date IS '结算周期结束日期（周日）';
COMMENT ON COLUMN src.src_fin_loop_statement.redemption_qty IS '有效核销张数';
COMMENT ON COLUMN src.src_fin_loop_statement.voided_qty IS '风控作废的核销张数（不计金额）';
COMMENT ON COLUMN src.src_fin_loop_statement.redemption_amt IS '核销结算金额（分，绝对值；方向见 redemption_direction）';
COMMENT ON COLUMN src.src_fin_loop_statement.redemption_direction IS '核销金额方向：merchant_pays-商户付给平台 platform_pays-平台付给商户（按各投放单价和方向轧差）';
COMMENT ON COLUMN src.src_fin_loop_statement.booking_qty IS '订场笔数（已支付 / 已完成、开始时间在周期内，已退款的不计）';
COMMENT ON COLUMN src.src_fin_loop_statement.booking_amt IS '订场实收金额（分）';
COMMENT ON COLUMN src.src_fin_loop_statement.booking_commission_rate IS '生成时的订场佣金比例';
COMMENT ON COLUMN src.src_fin_loop_statement.booking_commission_amt IS '平台订场佣金（分）';
COMMENT ON COLUMN src.src_fin_loop_statement.net_amt IS '净额（分）：正数商户付给平台，负数平台付给商户（订场款扣佣金后付给商户 + 平台补贴型核销）';
COMMENT ON COLUMN src.src_fin_loop_statement.statement_status IS '结算单状态：draft-待确认 confirmed-已确认 paid-已付款（线下打款后标记）';
COMMENT ON COLUMN src.src_fin_loop_statement.confirm_admin_id IS '确认人（后台账号ID）';
COMMENT ON COLUMN src.src_fin_loop_statement.confirm_time IS '确认时间';
COMMENT ON COLUMN src.src_fin_loop_statement.pay_time IS '标记已付款时间';
COMMENT ON COLUMN src.src_fin_loop_statement.create_time IS '生成时间';
COMMENT ON COLUMN src.src_fin_loop_statement.update_time IS '最后修改时间';

CREATE TABLE src.src_fin_loop_statement_line (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    statement_id  BIGINT      NOT NULL REFERENCES src.src_fin_loop_statement (id) ON DELETE CASCADE,
    line_type     TEXT        NOT NULL CHECK (line_type IN ('redemption', 'booking')),
    ref_id        BIGINT      NOT NULL,
    ref_no        TEXT        NOT NULL,
    user_id       BIGINT,
    amount_amt    BIGINT      NOT NULL DEFAULT 0,
    is_voided     BOOLEAN     NOT NULL DEFAULT false,
    occur_time    TIMESTAMPTZ NOT NULL,
    create_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (line_type, ref_id)
);
CREATE INDEX statement_line_statement ON src.src_fin_loop_statement_line (statement_id);
COMMENT ON TABLE src.src_fin_loop_statement_line IS '结算单明细：一条核销或一笔订场';
COMMENT ON COLUMN src.src_fin_loop_statement_line.id IS '明细ID';
COMMENT ON COLUMN src.src_fin_loop_statement_line.statement_id IS '结算单ID';
COMMENT ON COLUMN src.src_fin_loop_statement_line.line_type IS '明细类型：redemption-核销 booking-订场';
COMMENT ON COLUMN src.src_fin_loop_statement_line.ref_id IS '核销ID或订场ID';
COMMENT ON COLUMN src.src_fin_loop_statement_line.ref_no IS '核销流水号或订场单号';
COMMENT ON COLUMN src.src_fin_loop_statement_line.user_id IS '用户ID';
COMMENT ON COLUMN src.src_fin_loop_statement_line.amount_amt IS '金额（分）：核销为结算单价，订场为实收金额';
COMMENT ON COLUMN src.src_fin_loop_statement_line.is_voided IS '是否风控作废（作废的核销列出但不计金额）';
COMMENT ON COLUMN src.src_fin_loop_statement_line.occur_time IS '发生时间（核销时间或订场开始时间）';
COMMENT ON COLUMN src.src_fin_loop_statement_line.create_time IS '写入时间';

-- ---------------------------------------------------------------- 能量商城
CREATE TABLE src.src_ply_loop_shop_item (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_key          TEXT        NOT NULL UNIQUE CHECK (item_key ~ '^[a-z0-9_]{2,40}$'),
    item_name         TEXT        NOT NULL,
    item_type         TEXT        NOT NULL CHECK (item_type IN ('territory_skin', 'avatar_frame', 'map_marker')),
    price_energy_qty  INT         NOT NULL CHECK (price_energy_qty > 0),
    image_url         TEXT,
    preview_json      JSONB       NOT NULL DEFAULT '{}',
    description       TEXT        NOT NULL DEFAULT '',
    is_on_sale        BOOLEAN     NOT NULL DEFAULT true,
    limited_end_time  TIMESTAMPTZ,
    sort_no           INT         NOT NULL DEFAULT 0,
    create_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE src.src_ply_loop_shop_item IS '能量商城商品：只能用运动获得的能量兑换，没有付费入口';
COMMENT ON COLUMN src.src_ply_loop_shop_item.id IS '商品ID';
COMMENT ON COLUMN src.src_ply_loop_shop_item.item_key IS '商品标识（App 按它画样式，如 skin_neon、frame_gold）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.item_name IS '商品名称';
COMMENT ON COLUMN src.src_ply_loop_shop_item.item_type IS '商品类型：territory_skin-领地皮肤 avatar_frame-头像框 map_marker-地图位置标记';
COMMENT ON COLUMN src.src_ply_loop_shop_item.price_energy_qty IS '兑换价格（能量）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.image_url IS '商品图片地址';
COMMENT ON COLUMN src.src_ply_loop_shop_item.preview_json IS '样式预览（领地皮肤：fill 填充色、stroke 描边色、pattern 纹理；其他类型可自定）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.description IS '商品说明';
COMMENT ON COLUMN src.src_ply_loop_shop_item.is_on_sale IS '是否上架（下架后不能再兑换，已拥有的照常使用）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.limited_end_time IS '限时兑换截止时间（空为不限时）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.sort_no IS '排序（小的在前）';
COMMENT ON COLUMN src.src_ply_loop_shop_item.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_loop_shop_item.update_time IS '最后修改时间';

CREATE TABLE src.src_ply_loop_user_item (
    user_id           BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    item_id           BIGINT      NOT NULL REFERENCES src.src_ply_loop_shop_item (id),
    item_type         TEXT        NOT NULL CHECK (item_type IN ('territory_skin', 'avatar_frame', 'map_marker')),
    price_energy_qty  INT         NOT NULL,
    is_equipped       BOOLEAN     NOT NULL DEFAULT false,
    create_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, item_id)
);
CREATE UNIQUE INDEX user_item_equipped ON src.src_ply_loop_user_item (user_id, item_type) WHERE is_equipped;
CREATE INDEX user_item_item ON src.src_ply_loop_user_item (item_id);
COMMENT ON TABLE src.src_ply_loop_user_item IS '用户拥有的装扮（能量商城兑换），同类型同时只装备一个';
COMMENT ON COLUMN src.src_ply_loop_user_item.user_id IS '用户ID';
COMMENT ON COLUMN src.src_ply_loop_user_item.item_id IS '商品ID';
COMMENT ON COLUMN src.src_ply_loop_user_item.item_type IS '商品类型（冗余，保证同类型只装备一个）：territory_skin-领地皮肤 avatar_frame-头像框 map_marker-地图位置标记';
COMMENT ON COLUMN src.src_ply_loop_user_item.price_energy_qty IS '兑换时花费的能量';
COMMENT ON COLUMN src.src_ply_loop_user_item.is_equipped IS '是否装备中';
COMMENT ON COLUMN src.src_ply_loop_user_item.create_time IS '兑换时间';
COMMENT ON COLUMN src.src_ply_loop_user_item.update_time IS '最后修改时间（装备 / 卸下）';

INSERT INTO src.src_ply_loop_shop_item (item_key, item_name, item_type, price_energy_qty, preview_json, description, sort_no) VALUES
    ('skin_neon',     '霓虹领地皮肤', 'territory_skin', 800,  '{"fill":"#D9F26B","stroke":"#A0D911","pattern":"grid"}',   '荧光绿网格，夜里也一眼认出你的地盘', 10),
    ('skin_ocean',    '深海领地皮肤', 'territory_skin', 800,  '{"fill":"#69C0FF","stroke":"#1D39C4","pattern":"wave"}',   '蓝色波纹', 11),
    ('skin_sunset',   '落日领地皮肤', 'territory_skin', 1200, '{"fill":"#FFA940","stroke":"#D4380D","pattern":"stripe"}', '橙红斜纹', 12),
    ('frame_gold',    '金色头像框',   'avatar_frame',   600,  '{"color":"#FAAD14"}', '金色描边头像框', 20),
    ('frame_runner',  '跑者头像框',   'avatar_frame',   400,  '{"color":"#52C41A"}', '跑道纹头像框', 21),
    ('frame_night',   '夜跑头像框',   'avatar_frame',   500,  '{"color":"#2F54EB"}', '星空头像框', 22),
    ('marker_rabbit', '兔子位置标记', 'map_marker',     300,  '{"icon":"rabbit"}', '地图上你的位置显示成一只兔子', 30),
    ('marker_flame',  '火焰位置标记', 'map_marker',     300,  '{"icon":"flame"}', '地图上你的位置显示成一团火', 31),
    ('marker_star',   '星星位置标记', 'map_marker',     200,  '{"icon":"star"}', '地图上你的位置显示成一颗星', 32);
