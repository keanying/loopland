-- 商户（V2 第四批「本地生活与商户」）；商户员工账号绑定商户
CREATE TABLE src.src_mer_loop_merchant (
    id                       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_name            TEXT        NOT NULL,
    merchant_type            TEXT        NOT NULL CHECK (merchant_type IN ('venue', 'brand', 'store')),
    merchant_status          TEXT        NOT NULL DEFAULT 'reviewing' CHECK (merchant_status IN ('partner', 'pending_sign', 'reviewing', 'suspended')),
    contact_name             TEXT,
    contact_phone_enc        BYTEA,
    contact_phone_last4      TEXT,
    license_images_json      JSONB       NOT NULL DEFAULT '[]',
    booking_commission_rate  NUMERIC(5,4) NOT NULL DEFAULT 0 CHECK (booking_commission_rate BETWEEN 0 AND 1),
    remark                   TEXT,
    create_time              TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time              TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE src.src_mer_loop_merchant IS '商户：合作场馆、品牌、门店';
COMMENT ON COLUMN src.src_mer_loop_merchant.id IS '商户ID';
COMMENT ON COLUMN src.src_mer_loop_merchant.merchant_name IS '商户名称';
COMMENT ON COLUMN src.src_mer_loop_merchant.merchant_type IS '商户类型：venue-场馆 brand-品牌 store-门店';
COMMENT ON COLUMN src.src_mer_loop_merchant.merchant_status IS '合作状态：partner-合作中 pending_sign-待签约 reviewing-资质审核 suspended-暂停合作（场馆不可预订、投放不再发券，已发的券仍可核销）';
COMMENT ON COLUMN src.src_mer_loop_merchant.contact_name IS '联系人';
COMMENT ON COLUMN src.src_mer_loop_merchant.contact_phone_enc IS '联系人手机号（AES-256-GCM 加密）';
COMMENT ON COLUMN src.src_mer_loop_merchant.contact_phone_last4 IS '联系人手机号后 4 位（列表脱敏展示）';
COMMENT ON COLUMN src.src_mer_loop_merchant.license_images_json IS '资质图片地址列表（营业执照等，JSON 数组）';
COMMENT ON COLUMN src.src_mer_loop_merchant.booking_commission_rate IS '订场佣金比例（0-1，如 0.1 表示平台抽 10%）';
COMMENT ON COLUMN src.src_mer_loop_merchant.remark IS '运营备注';
COMMENT ON COLUMN src.src_mer_loop_merchant.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mer_loop_merchant.update_time IS '最后修改时间';

ALTER TABLE src.src_sys_loop_admin ADD COLUMN merchant_id BIGINT REFERENCES src.src_mer_loop_merchant (id);
COMMENT ON COLUMN src.src_sys_loop_admin.merchant_id IS '绑定的商户ID（只有 merchant 角色有值：商户员工只能操作本商户数据）';
