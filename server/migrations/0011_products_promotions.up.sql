-- V2 第五批「商户商品与开放平台」A 部分：商户商品、商品订单与退款、商品券（扩展券表）、
-- 次卡多次核销、官方活动与活动商品、结算单的商品部分（docs/api/v2-5-商户商品与开放平台.md）。

-- ---------------------------------------------------------------- 商户：商品佣金
ALTER TABLE src.src_mer_loop_merchant ADD COLUMN product_commission_rate NUMERIC(5,4) NOT NULL DEFAULT 0.08
    CHECK (product_commission_rate BETWEEN 0 AND 1);
COMMENT ON COLUMN src.src_mer_loop_merchant.product_commission_rate IS '商品佣金比例（0-1，默认 0.08：商品券核销金额平台抽 8%；仅 admin 可改）';

-- ---------------------------------------------------------------- 商品
CREATE TABLE src.src_mer_loop_product (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_id           BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    product_type          TEXT        NOT NULL CHECK (product_type IN ('package', 'voucher', 'pass')),
    product_title         TEXT        NOT NULL,
    subtitle              TEXT        NOT NULL DEFAULT '',
    description           TEXT        NOT NULL DEFAULT '',
    images_json           JSONB       NOT NULL DEFAULT '[]',
    rules                 TEXT        NOT NULL DEFAULT '',
    sports                TEXT[]      NOT NULL DEFAULT '{}',
    price_amt             INT         NOT NULL CHECK (price_amt BETWEEN 1 AND 1000000),
    original_amt          INT         CHECK (original_amt >= price_amt),
    use_qty               INT         NOT NULL DEFAULT 1 CHECK (use_qty BETWEEN 1 AND 100),
    valid_days            INT         CHECK (valid_days BETWEEN 1 AND 365),
    valid_until_date      DATE,
    stock_qty             INT         CHECK (stock_qty >= 0),
    sold_qty              INT         NOT NULL DEFAULT 0 CHECK (sold_qty >= 0),
    per_user_limit_qty    INT         NOT NULL DEFAULT 0 CHECK (per_user_limit_qty >= 0),
    is_refundable         BOOLEAN     NOT NULL DEFAULT true,
    is_allow_promotion    BOOLEAN     NOT NULL DEFAULT false,
    venue_ids             BIGINT[]    NOT NULL DEFAULT '{}',
    product_status        TEXT        NOT NULL DEFAULT 'draft'
                          CHECK (product_status IN ('draft', 'reviewing', 'on_sale', 'off_sale', 'rejected', 'banned')),
    review_note           TEXT,
    is_content_approved   BOOLEAN     NOT NULL DEFAULT false,
    pending_content_json  JSONB,
    is_archived           BOOLEAN     NOT NULL DEFAULT false,
    archive_time          TIMESTAMPTZ,
    create_admin_id       BIGINT,
    create_app_id         BIGINT,
    create_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((valid_days IS NULL) <> (valid_until_date IS NULL)),
    CHECK (product_type = 'pass' OR use_qty = 1)
);
CREATE INDEX product_merchant ON src.src_mer_loop_product (merchant_id, product_status) WHERE NOT is_archived;
CREATE INDEX product_on_sale ON src.src_mer_loop_product (merchant_id, sold_qty DESC) WHERE product_status = 'on_sale' AND NOT is_archived;
COMMENT ON TABLE src.src_mer_loop_product IS '商户商品：套餐券、代金券、次卡；商户自己维护（管理端商户账号或开放接口），上架前过内容审核，App 购买得券到店核销';
COMMENT ON COLUMN src.src_mer_loop_product.id IS '商品ID';
COMMENT ON COLUMN src.src_mer_loop_product.merchant_id IS '所属商户ID';
COMMENT ON COLUMN src.src_mer_loop_product.product_type IS '商品类型：package-套餐券 voucher-代金券（original_amt 为面值） pass-次卡（use_qty 次，每次核销用掉 1 次）';
COMMENT ON COLUMN src.src_mer_loop_product.product_title IS '商品标题（2-40 字，内容字段，改动需审核）';
COMMENT ON COLUMN src.src_mer_loop_product.subtitle IS '副标题（≤40 字，内容字段）';
COMMENT ON COLUMN src.src_mer_loop_product.description IS '商品说明（≤1000 字，内容字段）';
COMMENT ON COLUMN src.src_mer_loop_product.images_json IS '商品图片地址列表（1-9 张，JSON 数组，内容字段）';
COMMENT ON COLUMN src.src_mer_loop_product.rules IS '使用规则（≤500 字，内容字段）';
COMMENT ON COLUMN src.src_mer_loop_product.sports IS '适用运动分类（同场馆 sports 取值）';
COMMENT ON COLUMN src.src_mer_loop_product.price_amt IS '售价（分，1-1000000）';
COMMENT ON COLUMN src.src_mer_loop_product.original_amt IS '门市价 / 代金券面值（分，可空；填了须 ≥ 售价）';
COMMENT ON COLUMN src.src_mer_loop_product.use_qty IS '可用次数（次卡 2-100，其他类型固定 1）';
COMMENT ON COLUMN src.src_mer_loop_product.valid_days IS '有效期：购买后 N 天（1-365；与 valid_until_date 二选一）';
COMMENT ON COLUMN src.src_mer_loop_product.valid_until_date IS '有效期：固定截止日（当天 23:59:59 Asia/Shanghai；与 valid_days 二选一）';
COMMENT ON COLUMN src.src_mer_loop_product.stock_qty IS '剩余库存（件；空为不限；下单即扣减锁定，取消 / 超时未支付退回）';
COMMENT ON COLUMN src.src_mer_loop_product.sold_qty IS '已售件数（支付成功累计，App 展示「已售」、按它排序）';
COMMENT ON COLUMN src.src_mer_loop_product.per_user_limit_qty IS '每人限购件数（0 为不限；按待支付、已支付且未全额退款的件数算）';
COMMENT ON COLUMN src.src_mer_loop_product.is_refundable IS '未使用的券是否可退款（过期未使用的也自动退款）；改动只影响之后的购买';
COMMENT ON COLUMN src.src_mer_loop_product.is_allow_promotion IS '是否允许平台把商品选入官方活动（商户授权；关掉后不能再被选入，已进行中的不受影响）';
COMMENT ON COLUMN src.src_mer_loop_product.venue_ids IS '适用门店（本商户场馆ID列表；空数组 = 本商户所有场馆都可用）';
COMMENT ON COLUMN src.src_mer_loop_product.product_status IS '商品状态：draft-草稿 reviewing-审核中（人工审核队列） on_sale-在售 off_sale-已下架（商户下架） rejected-审核驳回（可修改后重新提交） banned-平台强制下架（只能修改后重新提交审核）';
COMMENT ON COLUMN src.src_mer_loop_product.review_note IS '审核 / 封禁说明（驳回原因、强制下架原因、待审改动被驳回的原因）';
COMMENT ON COLUMN src.src_mer_loop_product.is_content_approved IS '当前内容是否已审核通过（下架后改了内容再上架要重新审核）';
COMMENT ON COLUMN src.src_mer_loop_product.pending_content_json IS '在售商品待审的内容改动（title / subtitle / description / images / rules 的完整新版本；空为没有待审改动）';
COMMENT ON COLUMN src.src_mer_loop_product.is_archived IS '是否已归档（卖出过的商品删除时归档：列表不再显示，已售出的券照常可用）';
COMMENT ON COLUMN src.src_mer_loop_product.archive_time IS '归档时间';
COMMENT ON COLUMN src.src_mer_loop_product.create_admin_id IS '创建人（后台商户账号ID；开放接口创建的为空）';
COMMENT ON COLUMN src.src_mer_loop_product.create_app_id IS '创建的开放平台应用ID（src.src_mer_loop_open_app.id；管理端创建的为空）';
COMMENT ON COLUMN src.src_mer_loop_product.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_product.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 官方活动
CREATE TABLE src.src_mkt_loop_promotion (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    promotion_title       TEXT        NOT NULL,
    subtitle              TEXT        NOT NULL DEFAULT '',
    banner_url            TEXT,
    description           TEXT        NOT NULL DEFAULT '',
    start_time            TIMESTAMPTZ NOT NULL,
    end_time              TIMESTAMPTZ NOT NULL,
    is_apply_open         BOOLEAN     NOT NULL DEFAULT false,
    apply_deadline_time   TIMESTAMPTZ,
    promotion_status      TEXT        NOT NULL DEFAULT 'draft' CHECK (promotion_status IN ('draft', 'published', 'cancelled')),
    create_admin_id       BIGINT,
    create_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
COMMENT ON TABLE src.src_mkt_loop_promotion IS '官方活动：平台运营的专题 / 限时活动价，商品来自商户授权或商户报名';
COMMENT ON COLUMN src.src_mkt_loop_promotion.id IS '官方活动ID';
COMMENT ON COLUMN src.src_mkt_loop_promotion.promotion_title IS '活动标题';
COMMENT ON COLUMN src.src_mkt_loop_promotion.subtitle IS '副标题';
COMMENT ON COLUMN src.src_mkt_loop_promotion.banner_url IS '横幅图地址';
COMMENT ON COLUMN src.src_mkt_loop_promotion.description IS '活动说明';
COMMENT ON COLUMN src.src_mkt_loop_promotion.start_time IS '开始时间';
COMMENT ON COLUMN src.src_mkt_loop_promotion.end_time IS '结束时间';
COMMENT ON COLUMN src.src_mkt_loop_promotion.is_apply_open IS '是否开放商户报名';
COMMENT ON COLUMN src.src_mkt_loop_promotion.apply_deadline_time IS '报名截止时间（空为活动结束前都可报名）';
COMMENT ON COLUMN src.src_mkt_loop_promotion.promotion_status IS '活动状态：draft-草稿（不对外） published-已发布（按时间显示为 scheduled 即将开始 / active 进行中 / ended 已结束） cancelled-已取消';
COMMENT ON COLUMN src.src_mkt_loop_promotion.create_admin_id IS '创建人（后台账号ID）';
COMMENT ON COLUMN src.src_mkt_loop_promotion.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mkt_loop_promotion.update_time IS '最后修改时间';

CREATE TABLE src.src_mkt_loop_promotion_entry (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    promotion_id          BIGINT      NOT NULL REFERENCES src.src_mkt_loop_promotion (id) ON DELETE CASCADE,
    product_id            BIGINT      NOT NULL REFERENCES src.src_mer_loop_product (id) ON DELETE CASCADE,
    merchant_id           BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    promo_price_amt       INT         NOT NULL CHECK (promo_price_amt > 0),
    platform_subsidy_amt  INT         NOT NULL DEFAULT 0 CHECK (platform_subsidy_amt >= 0),
    promo_stock_qty       INT         CHECK (promo_stock_qty >= 0),
    promo_sold_qty        INT         NOT NULL DEFAULT 0 CHECK (promo_sold_qty >= 0),
    sort_no               INT         NOT NULL DEFAULT 0,
    source_type           TEXT        NOT NULL CHECK (source_type IN ('platform', 'merchant')),
    entry_status          TEXT        NOT NULL
                          CHECK (entry_status IN ('pending_merchant', 'pending_platform', 'active', 'rejected', 'withdrawn', 'removed')),
    note                  TEXT        NOT NULL DEFAULT '',
    decide_time           TIMESTAMPTZ,
    create_admin_id       BIGINT,
    create_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX promotion_entry_live ON src.src_mkt_loop_promotion_entry (promotion_id, product_id)
    WHERE entry_status IN ('pending_merchant', 'pending_platform', 'active');
CREATE INDEX promotion_entry_product ON src.src_mkt_loop_promotion_entry (product_id) WHERE entry_status = 'active';
CREATE INDEX promotion_entry_merchant ON src.src_mkt_loop_promotion_entry (merchant_id, entry_status);
COMMENT ON TABLE src.src_mkt_loop_promotion_entry IS '官方活动商品条目：平台选品（商户授权的商品）或商户报名；活动价由商户让利，平台可加每件补贴';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.id IS '活动条目ID';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.promotion_id IS '官方活动ID';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.product_id IS '商品ID';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.merchant_id IS '商品所属商户ID（冗余，便于商户查看本商户条目）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.promo_price_amt IS '活动价（分，≤ 商品售价；等于售价为不让利）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.platform_subsidy_amt IS '平台每件补贴（分）：按核销补给商户，进结算单';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.promo_stock_qty IS '活动库存（件；空为不限）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.promo_sold_qty IS '活动已售件数（含待支付锁定的，取消 / 超时退回）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.sort_no IS '排序（小的在前）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.source_type IS '来源：platform-平台选品 merchant-商户报名';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.entry_status IS '条目状态：pending_merchant-待商户同意（平台选品且活动价低于售价） pending_platform-待平台审核（商户报名） active-生效 rejected-已拒绝（商户拒绝邀请或平台驳回报名） withdrawn-商户已退出 removed-平台已移除';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.note IS '备注（驳回 / 拒绝 / 移除原因）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.decide_time IS '最近一次状态决定时间（同意、拒绝、通过、驳回、退出、移除）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.create_admin_id IS '创建人（后台账号ID；开放接口报名的为空）';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mkt_loop_promotion_entry.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 商品订单
ALTER TABLE src.src_ord_loop_order DROP CONSTRAINT src_ord_loop_order_biz_type_check;
ALTER TABLE src.src_ord_loop_order ADD CONSTRAINT src_ord_loop_order_biz_type_check CHECK (biz_type IN ('membership', 'booking', 'race_fee', 'product'));
COMMENT ON TABLE src.src_ord_loop_order IS '订单：会员、订场、赛事报名费、商户商品（支付回调和退款按 biz_type 分发）';
COMMENT ON COLUMN src.src_ord_loop_order.biz_type IS '业务类型：membership-会员 booking-订场 race_fee-赛事报名费 product-商户商品（可部分退款，见 src.src_ord_loop_product_refund）';

CREATE TABLE src.src_ord_loop_product_order (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_no              TEXT        NOT NULL UNIQUE,
    user_id               BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    product_id            BIGINT      NOT NULL REFERENCES src.src_mer_loop_product (id),
    merchant_id           BIGINT      NOT NULL REFERENCES src.src_mer_loop_merchant (id),
    product_type          TEXT        NOT NULL CHECK (product_type IN ('package', 'voucher', 'pass')),
    product_title         TEXT        NOT NULL,
    image_url             TEXT,
    qty                   INT         NOT NULL CHECK (qty BETWEEN 1 AND 10),
    unit_price_amt        INT         NOT NULL CHECK (unit_price_amt > 0),
    amount_amt            INT         NOT NULL CHECK (amount_amt > 0),
    refund_amt            INT         NOT NULL DEFAULT 0 CHECK (refund_amt >= 0),
    promotion_id          BIGINT      REFERENCES src.src_mkt_loop_promotion (id) ON DELETE SET NULL,
    promotion_entry_id    BIGINT      REFERENCES src.src_mkt_loop_promotion_entry (id) ON DELETE SET NULL,
    promo_price_amt       INT,
    platform_subsidy_amt  INT         NOT NULL DEFAULT 0,
    use_qty               INT         NOT NULL DEFAULT 1,
    valid_days            INT,
    valid_until_date      DATE,
    is_refundable         BOOLEAN     NOT NULL,
    venue_ids             BIGINT[]    NOT NULL DEFAULT '{}',
    rules                 TEXT        NOT NULL DEFAULT '',
    subtitle              TEXT        NOT NULL DEFAULT '',
    order_status          TEXT        NOT NULL DEFAULT 'pending'
                          CHECK (order_status IN ('pending', 'paid', 'completed', 'refunding', 'refunded', 'cancelled')),
    channel               TEXT        NOT NULL,
    pay_order_no          TEXT        REFERENCES src.src_ord_loop_order (order_no),
    pay_expire_time       TIMESTAMPTZ NOT NULL,
    paid_time             TIMESTAMPTZ,
    cancel_time           TIMESTAMPTZ,
    create_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (amount_amt = unit_price_amt * qty)
);
CREATE INDEX product_order_user ON src.src_ord_loop_product_order (user_id, create_time DESC);
CREATE INDEX product_order_product ON src.src_ord_loop_product_order (product_id, user_id);
CREATE INDEX product_order_merchant ON src.src_ord_loop_product_order (merchant_id, create_time DESC);
CREATE INDEX product_order_pending ON src.src_ord_loop_product_order (pay_expire_time) WHERE order_status = 'pending';
CREATE UNIQUE INDEX product_order_pay ON src.src_ord_loop_product_order (pay_order_no) WHERE pay_order_no IS NOT NULL;
COMMENT ON TABLE src.src_ord_loop_product_order IS '商品订单：App 购买商户商品，支付成功后每件发 1 张券；下单即锁库存，超时未支付自动取消';
COMMENT ON COLUMN src.src_ord_loop_product_order.id IS '商品订单ID';
COMMENT ON COLUMN src.src_ord_loop_product_order.order_no IS '商品订单号（PO + 14 位时间 + 5 位随机数）';
COMMENT ON COLUMN src.src_ord_loop_product_order.user_id IS '购买用户ID';
COMMENT ON COLUMN src.src_ord_loop_product_order.product_id IS '商品ID';
COMMENT ON COLUMN src.src_ord_loop_product_order.merchant_id IS '商户ID';
COMMENT ON COLUMN src.src_ord_loop_product_order.product_type IS '下单时的商品类型快照：package-套餐券 voucher-代金券 pass-次卡';
COMMENT ON COLUMN src.src_ord_loop_product_order.product_title IS '下单时的商品标题快照';
COMMENT ON COLUMN src.src_ord_loop_product_order.image_url IS '下单时的商品首图快照';
COMMENT ON COLUMN src.src_ord_loop_product_order.qty IS '购买件数（1-10）';
COMMENT ON COLUMN src.src_ord_loop_product_order.unit_price_amt IS '实付单价（分；有活动价时为活动价）';
COMMENT ON COLUMN src.src_ord_loop_product_order.amount_amt IS '实付金额（分）= 单价 × 件数';
COMMENT ON COLUMN src.src_ord_loop_product_order.refund_amt IS '累计退款金额（分；部分退款时订单状态保持 paid / completed）';
COMMENT ON COLUMN src.src_ord_loop_product_order.promotion_id IS '按活动价下单时的官方活动ID';
COMMENT ON COLUMN src.src_ord_loop_product_order.promotion_entry_id IS '按活动价下单时的活动条目ID（活动库存按它锁定）';
COMMENT ON COLUMN src.src_ord_loop_product_order.promo_price_amt IS '下单时的活动价（分；没有活动价为空）';
COMMENT ON COLUMN src.src_ord_loop_product_order.platform_subsidy_amt IS '下单时活动的平台每件补贴（分，按核销进结算）';
COMMENT ON COLUMN src.src_ord_loop_product_order.use_qty IS '每张券可用次数快照（次卡 > 1）';
COMMENT ON COLUMN src.src_ord_loop_product_order.valid_days IS '有效期快照：购买后 N 天（与 valid_until_date 二选一）';
COMMENT ON COLUMN src.src_ord_loop_product_order.valid_until_date IS '有效期快照：固定截止日';
COMMENT ON COLUMN src.src_ord_loop_product_order.is_refundable IS '下单时商品是否可退（未使用 / 过期未使用的券可退）';
COMMENT ON COLUMN src.src_ord_loop_product_order.venue_ids IS '下单时的适用门店快照（空为本商户所有场馆）';
COMMENT ON COLUMN src.src_ord_loop_product_order.rules IS '下单时的使用规则快照（写入券的权益说明）';
COMMENT ON COLUMN src.src_ord_loop_product_order.subtitle IS '下单时的副标题快照（写入券的权益说明）';
COMMENT ON COLUMN src.src_ord_loop_product_order.order_status IS '订单状态：pending-待支付 paid-已支付（还有未使用的券） completed-已完成（券全部用完 / 过期且不可退 / 部分退款后无可用券） refunding-退款中 refunded-已全额退款 cancelled-已取消（未支付取消或超时）';
COMMENT ON COLUMN src.src_ord_loop_product_order.channel IS '支付方式：wechat_app-微信 alipay_app-支付宝 mock-模拟（仅 dev）';
COMMENT ON COLUMN src.src_ord_loop_product_order.pay_order_no IS '支付订单号（src.src_ord_loop_order.order_no，biz_type=product）';
COMMENT ON COLUMN src.src_ord_loop_product_order.pay_expire_time IS '支付截止时间（下单后 booking.pay_timeout_min 分钟，默认 15）';
COMMENT ON COLUMN src.src_ord_loop_product_order.paid_time IS '支付时间';
COMMENT ON COLUMN src.src_ord_loop_product_order.cancel_time IS '取消时间';
COMMENT ON COLUMN src.src_ord_loop_product_order.create_time IS '下单时间';
COMMENT ON COLUMN src.src_ord_loop_product_order.update_time IS '最后修改时间';

CREATE TABLE src.src_ord_loop_product_refund (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    refund_no         TEXT        NOT NULL UNIQUE,
    product_order_id  BIGINT      NOT NULL REFERENCES src.src_ord_loop_product_order (id) ON DELETE CASCADE,
    pay_order_no      TEXT        NOT NULL REFERENCES src.src_ord_loop_order (order_no),
    refund_amt        INT         NOT NULL CHECK (refund_amt > 0),
    coupon_qty        INT         NOT NULL DEFAULT 0,
    refund_type       TEXT        NOT NULL CHECK (refund_type IN ('user', 'admin', 'auto_expire')),
    refund_reason     TEXT        NOT NULL DEFAULT '',
    refund_status     TEXT        NOT NULL DEFAULT 'pending' CHECK (refund_status IN ('pending', 'succeeded')),
    admin_id          BIGINT,
    retry_qty         INT         NOT NULL DEFAULT 0,
    success_time      TIMESTAMPTZ,
    create_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX product_refund_order ON src.src_ord_loop_product_refund (product_order_id);
CREATE INDEX product_refund_pending ON src.src_ord_loop_product_refund (create_time) WHERE refund_status = 'pending';
COMMENT ON TABLE src.src_ord_loop_product_refund IS '商品订单退款：每次退款退回当时所有未使用的券，按原路部分退款（渠道失败时后台任务重试）';
COMMENT ON COLUMN src.src_ord_loop_product_refund.id IS '退款ID';
COMMENT ON COLUMN src.src_ord_loop_product_refund.refund_no IS '退款单号（渠道的商户退款单号 out_refund_no / out_request_no）';
COMMENT ON COLUMN src.src_ord_loop_product_refund.product_order_id IS '商品订单ID';
COMMENT ON COLUMN src.src_ord_loop_product_refund.pay_order_no IS '支付订单号';
COMMENT ON COLUMN src.src_ord_loop_product_refund.refund_amt IS '退款金额（分）：未使用券的实付单价之和（次卡只退剩余次数对应的金额）';
COMMENT ON COLUMN src.src_ord_loop_product_refund.coupon_qty IS '本次退掉的券张数';
COMMENT ON COLUMN src.src_ord_loop_product_refund.refund_type IS '退款类型：user-用户申请 admin-平台客服退款 auto_expire-过期未使用自动退款（每天 02:00）';
COMMENT ON COLUMN src.src_ord_loop_product_refund.refund_reason IS '退款原因';
COMMENT ON COLUMN src.src_ord_loop_product_refund.refund_status IS '退款状态：pending-退款中（等待渠道，失败自动重试） succeeded-已到账';
COMMENT ON COLUMN src.src_ord_loop_product_refund.admin_id IS '操作退款的后台账号ID（平台退款时）';
COMMENT ON COLUMN src.src_ord_loop_product_refund.retry_qty IS '渠道退款重试次数';
COMMENT ON COLUMN src.src_ord_loop_product_refund.success_time IS '退款成功时间';
COMMENT ON COLUMN src.src_ord_loop_product_refund.create_time IS '申请时间';
COMMENT ON COLUMN src.src_ord_loop_product_refund.update_time IS '最后修改时间';

-- ---------------------------------------------------------------- 券：商品券、次卡
ALTER TABLE src.src_mkt_loop_coupon ALTER COLUMN drop_id DROP NOT NULL;
ALTER TABLE src.src_mkt_loop_coupon DROP CONSTRAINT src_mkt_loop_coupon_source_type_check;
ALTER TABLE src.src_mkt_loop_coupon ADD CONSTRAINT src_mkt_loop_coupon_source_type_check CHECK (source_type IN ('supply', 'chest', 'stronghold', 'product'));
ALTER TABLE src.src_mkt_loop_coupon DROP CONSTRAINT src_mkt_loop_coupon_coupon_status_check;
ALTER TABLE src.src_mkt_loop_coupon ADD CONSTRAINT src_mkt_loop_coupon_coupon_status_check
    CHECK (coupon_status IN ('unused', 'used', 'expired', 'voided', 'refunded'));
ALTER TABLE src.src_mkt_loop_coupon
    ADD COLUMN product_id            BIGINT REFERENCES src.src_mer_loop_product (id),
    ADD COLUMN product_order_id      BIGINT REFERENCES src.src_ord_loop_product_order (id) ON DELETE CASCADE,
    ADD COLUMN use_qty               INT     NOT NULL DEFAULT 1 CHECK (use_qty BETWEEN 1 AND 100),
    ADD COLUMN left_use_qty          INT     NOT NULL DEFAULT 1 CHECK (left_use_qty >= 0),
    ADD COLUMN paid_amt              INT     NOT NULL DEFAULT 0,
    ADD COLUMN platform_subsidy_amt  INT     NOT NULL DEFAULT 0,
    ADD COLUMN is_refundable         BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN venue_ids             BIGINT[] NOT NULL DEFAULT '{}',
    ADD COLUMN refund_id             BIGINT REFERENCES src.src_ord_loop_product_refund (id),
    ADD COLUMN refund_time           TIMESTAMPTZ;
ALTER TABLE src.src_mkt_loop_coupon ADD CONSTRAINT coupon_source_ref CHECK (
    (source_type = 'product' AND product_order_id IS NOT NULL) OR (source_type <> 'product' AND drop_id IS NOT NULL));
CREATE INDEX coupon_product_order ON src.src_mkt_loop_coupon (product_order_id) WHERE product_order_id IS NOT NULL;
COMMENT ON TABLE src.src_mkt_loop_coupon IS '用户的券（卡券包）：投放券（运动 / 签到免费领取，每人每个投放每天最多 1 张）和商品券（购买商户商品，每件 1 张）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.drop_id IS '来源投放ID（投放券必填，商品券为空）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.source_type IS '来源类型：supply-补给站 chest-商户宝箱 stronghold-据点签到 product-购买商品';
COMMENT ON COLUMN src.src_mkt_loop_coupon.source_name IS '来源名称（领取时的投放名称，商品券为商品标题）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.coupon_status IS '券状态：unused-未使用（次卡还有剩余次数） used-已核销（次卡次数用完） expired-已过期 voided-已作废（发券的运动记录被风控作废） refunded-已退款（商品券）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.product_id IS '来源商品ID（商品券）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.product_order_id IS '来源商品订单ID（商品券）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.use_qty IS '可用总次数（次卡 > 1，其他为 1）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.left_use_qty IS '剩余次数（每次核销减 1，到 0 变 used）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.paid_amt IS '这张券的实付金额（分，商品券；结算按 实付 ÷ 次数 计每次核销金额）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.platform_subsidy_amt IS '这张券的官方活动平台补贴（分，商品券；按核销进结算，次卡按次数分摊）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.is_refundable IS '是否可退（商品券；过期未使用的每天 02:00 自动退款）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.venue_ids IS '适用门店（商品券；核销时校验，空为本商户所有场馆）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.refund_id IS '退款ID（src.src_ord_loop_product_refund.id）';
COMMENT ON COLUMN src.src_mkt_loop_coupon.refund_time IS '退款时间';

-- ---------------------------------------------------------------- 核销：商品券（次卡每次一条）
ALTER TABLE src.src_mer_loop_redemption DROP CONSTRAINT src_mer_loop_redemption_coupon_id_key;
CREATE INDEX redemption_coupon ON src.src_mer_loop_redemption (coupon_id);
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN drop_id DROP NOT NULL;
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN activity_id DROP NOT NULL;
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN admin_id DROP NOT NULL;
ALTER TABLE src.src_mer_loop_redemption
    ADD COLUMN redemption_type       TEXT   NOT NULL DEFAULT 'drop' CHECK (redemption_type IN ('drop', 'product')),
    ADD COLUMN product_id            BIGINT,
    ADD COLUMN product_order_id      BIGINT,
    ADD COLUMN promotion_id          BIGINT,
    ADD COLUMN product_amt           INT    NOT NULL DEFAULT 0,
    ADD COLUMN product_subsidy_amt   INT    NOT NULL DEFAULT 0,
    ADD COLUMN open_app_id           BIGINT;
ALTER TABLE src.src_mer_loop_redemption ADD CONSTRAINT redemption_type_ref CHECK (
    (redemption_type = 'drop' AND drop_id IS NOT NULL AND activity_id IS NOT NULL) OR (redemption_type = 'product' AND product_order_id IS NOT NULL));
ALTER TABLE src.src_mer_loop_redemption ADD CONSTRAINT redemption_operator CHECK (admin_id IS NOT NULL OR open_app_id IS NOT NULL);
CREATE INDEX redemption_product_order ON src.src_mer_loop_redemption (product_order_id) WHERE product_order_id IS NOT NULL;
COMMENT ON TABLE src.src_mer_loop_redemption IS '核销记录：投放券需要用户当天有一条有效运动记录；商品券不需要，次卡每次核销一条';
COMMENT ON COLUMN src.src_mer_loop_redemption.coupon_id IS '核销的券ID（次卡同一张券有多条）';
COMMENT ON COLUMN src.src_mer_loop_redemption.drop_id IS '券来源投放ID（投放券，每日核销上限按它算；商品券为空）';
COMMENT ON COLUMN src.src_mer_loop_redemption.admin_id IS '操作核销的后台账号ID（商户员工或运营；开放接口核销为空）';
COMMENT ON COLUMN src.src_mer_loop_redemption.activity_id IS '核销所依赖的当天运动记录ID（投放券；被风控作废且当天没有其他有效记录时核销作废；商品券为空）';
COMMENT ON COLUMN src.src_mer_loop_redemption.redemption_type IS '核销类型：drop-投放券（按投放单价和方向结算） product-商品券（按实付金额结算给商户，扣商品佣金，加活动补贴）';
COMMENT ON COLUMN src.src_mer_loop_redemption.product_id IS '商品ID（商品券）';
COMMENT ON COLUMN src.src_mer_loop_redemption.product_order_id IS '商品订单ID（商品券）';
COMMENT ON COLUMN src.src_mer_loop_redemption.promotion_id IS '按活动价购买时的官方活动ID（商品券）';
COMMENT ON COLUMN src.src_mer_loop_redemption.product_amt IS '这次核销对应的实付金额（分，商品券；次卡 = 实付单价 ÷ 次数 四舍五入到分）';
COMMENT ON COLUMN src.src_mer_loop_redemption.product_subsidy_amt IS '这次核销对应的官方活动平台补贴（分，商品券；次卡按次数分摊）';
COMMENT ON COLUMN src.src_mer_loop_redemption.open_app_id IS '通过开放接口核销时的应用ID（src.src_mer_loop_open_app.id）';

-- ---------------------------------------------------------------- 结算单：商品部分
ALTER TABLE src.src_fin_loop_statement
    ADD COLUMN product_qty              INT          NOT NULL DEFAULT 0,
    ADD COLUMN product_amt              BIGINT       NOT NULL DEFAULT 0,
    ADD COLUMN product_commission_rate  NUMERIC(5,4) NOT NULL DEFAULT 0,
    ADD COLUMN product_commission_amt   BIGINT       NOT NULL DEFAULT 0,
    ADD COLUMN product_subsidy_amt      BIGINT       NOT NULL DEFAULT 0;
COMMENT ON TABLE src.src_fin_loop_statement IS '结算单：每商户每周一张（周一 03:00 生成上周的），含投放券核销、订场和商品券核销';
COMMENT ON COLUMN src.src_fin_loop_statement.redemption_qty IS '有效的投放券核销张数（商品券核销见 product_qty）';
COMMENT ON COLUMN src.src_fin_loop_statement.product_qty IS '周期内商品券核销次数';
COMMENT ON COLUMN src.src_fin_loop_statement.product_amt IS '商品券核销对应的实付金额（分；次卡按 实付单价 ÷ 次数 四舍五入到分）';
COMMENT ON COLUMN src.src_fin_loop_statement.product_commission_rate IS '生成时的商品佣金比例';
COMMENT ON COLUMN src.src_fin_loop_statement.product_commission_amt IS '平台商品佣金（分）= round(product_amt × product_commission_rate)';
COMMENT ON COLUMN src.src_fin_loop_statement.product_subsidy_amt IS '官方活动平台补贴（分，按核销计）';
COMMENT ON COLUMN src.src_fin_loop_statement.net_amt IS '净额（分）= 核销轧差 − (订场款 − 订场佣金) − (商品款 − 商品佣金) − 活动补贴：正数商户付给平台，负数平台付给商户';

ALTER TABLE src.src_fin_loop_statement_line DROP CONSTRAINT src_fin_loop_statement_line_line_type_check;
ALTER TABLE src.src_fin_loop_statement_line ADD CONSTRAINT src_fin_loop_statement_line_line_type_check CHECK (line_type IN ('redemption', 'booking', 'product'));
ALTER TABLE src.src_fin_loop_statement_line ADD COLUMN subsidy_amt BIGINT NOT NULL DEFAULT 0;
COMMENT ON TABLE src.src_fin_loop_statement_line IS '结算单明细：一条投放券核销、一笔订场或一次商品券核销';
COMMENT ON COLUMN src.src_fin_loop_statement_line.line_type IS '明细类型：redemption-投放券核销 booking-订场 product-商品券核销';
COMMENT ON COLUMN src.src_fin_loop_statement_line.ref_id IS '核销ID或订场ID（product 为核销ID）';
COMMENT ON COLUMN src.src_fin_loop_statement_line.amount_amt IS '金额（分）：投放券核销为结算单价，订场为实收金额，商品券核销为这次核销对应的实付金额';
COMMENT ON COLUMN src.src_fin_loop_statement_line.subsidy_amt IS '官方活动平台补贴（分，仅商品券核销）';

-- ---------------------------------------------------------------- 内容审核：商品
ALTER TABLE src.src_cnt_loop_review_task DROP CONSTRAINT src_cnt_loop_review_task_target_type_check;
ALTER TABLE src.src_cnt_loop_review_task ADD CONSTRAINT src_cnt_loop_review_task_target_type_check
    CHECK (target_type IN ('post', 'comment', 'nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio', 'meetup', 'product'));
COMMENT ON TABLE src.src_cnt_loop_review_task IS '内容审核任务：动态、评论、昵称、头像、跑团名称/头像、简介、组局、商户商品；管理端审核队列';
COMMENT ON COLUMN src.src_cnt_loop_review_task.target_type IS '审核对象类型：post-动态 comment-评论 nickname-用户昵称 avatar-用户头像 crew_name-跑团名称 crew_avatar-跑团头像 bio-个人简介 meetup-组局 product-商户商品（新提交或在售商品的内容改动）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.target_id IS '审核对象ID：动态/评论/组局/商品为各自ID，昵称/头像/简介为用户ID，跑团名称/头像为跑团ID';
COMMENT ON COLUMN src.src_cnt_loop_review_task.user_id IS '内容作者（用户ID；商户商品为空）';
