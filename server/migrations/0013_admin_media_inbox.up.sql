-- V2 第六批「管理端图片上传与站内信」（docs/api/v2-6-管理端图片上传与站内信.md）：
-- 图片表记录管理端账号、商户、开放平台应用上传的图片；管理端站内信。

-- ---------------------------------------------------------------- 图片上传者
ALTER TABLE src.src_cnt_loop_media ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE src.src_cnt_loop_media ADD COLUMN admin_id BIGINT REFERENCES src.src_sys_loop_admin (id);
ALTER TABLE src.src_cnt_loop_media ADD COLUMN merchant_id BIGINT REFERENCES src.src_mer_loop_merchant (id);
ALTER TABLE src.src_cnt_loop_media ADD COLUMN open_app_id BIGINT REFERENCES src.src_mer_loop_open_app (id) ON DELETE SET NULL;
ALTER TABLE src.src_cnt_loop_media ADD CONSTRAINT media_uploader_check CHECK (num_nonnulls(user_id, admin_id, merchant_id, open_app_id) >= 1);
ALTER TABLE src.src_cnt_loop_media DROP CONSTRAINT src_cnt_loop_media_purpose_type_check;
ALTER TABLE src.src_cnt_loop_media ADD CONSTRAINT src_cnt_loop_media_purpose_type_check CHECK (purpose_type IN ('post', 'avatar', 'crew_avatar', 'chat',
    'product', 'promotion_banner', 'venue_cover', 'merchant_license', 'campaign_banner', 'shop_item'));
CREATE INDEX media_admin_day ON src.src_cnt_loop_media (admin_id, create_time) WHERE admin_id IS NOT NULL;
CREATE INDEX media_open_app_day ON src.src_cnt_loop_media (open_app_id, create_time) WHERE open_app_id IS NOT NULL;
COMMENT ON TABLE src.src_cnt_loop_media IS '上传的图片：App 用户（动态、头像、跑团头像、聊天图片）、管理端账号（商品图、活动横幅、场馆封面、商户资质、联名横幅、能量商城商品图）、开放平台应用（商品图）';
COMMENT ON COLUMN src.src_cnt_loop_media.user_id IS '上传者（App 用户ID；管理端、开放平台上传的为空）';
COMMENT ON COLUMN src.src_cnt_loop_media.admin_id IS '上传者（管理端账号ID；App、开放平台上传的为空）';
COMMENT ON COLUMN src.src_cnt_loop_media.merchant_id IS '所属商户ID（商户员工或开放平台应用上传时为其商户，其余为空）';
COMMENT ON COLUMN src.src_cnt_loop_media.open_app_id IS '上传者（开放平台应用ID；应用删除后置空，仍保留 merchant_id）';
COMMENT ON COLUMN src.src_cnt_loop_media.purpose_type IS '用途：post-动态图片 avatar-用户头像 crew_avatar-跑团头像 chat-聊天图片（以上 App）；product-商品图片（商户员工、开放平台） promotion_banner-官方活动横幅 venue_cover-场馆封面 merchant_license-商户资质 campaign_banner-联名活动横幅 shop_item-能量商城商品图（以上管理端）';
COMMENT ON COLUMN src.src_cnt_loop_media.object_key IS '存储里的对象路径，如 post/2026/11/21/<随机>.jpg、product/2026/11/23/<随机>.jpg';

-- ---------------------------------------------------------------- 管理端站内信
CREATE TABLE src.src_msg_loop_admin_message (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id       BIGINT      NOT NULL REFERENCES src.src_sys_loop_admin (id) ON DELETE CASCADE,
    category_type  TEXT        NOT NULL CHECK (category_type IN ('product', 'promotion', 'settlement', 'openapi', 'review', 'system')),
    level_type     TEXT        NOT NULL DEFAULT 'info' CHECK (level_type IN ('info', 'success', 'warning', 'error')),
    title          TEXT        NOT NULL,
    body_text      TEXT        NOT NULL DEFAULT '',
    link_url       TEXT,
    is_read        BOOLEAN     NOT NULL DEFAULT false,
    read_time      TIMESTAMPTZ,
    ref_type       TEXT,
    ref_id         BIGINT,
    create_time    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX admin_message_inbox ON src.src_msg_loop_admin_message (admin_id, is_read, create_time);
CREATE INDEX admin_message_ref ON src.src_msg_loop_admin_message (ref_type, ref_id, create_time) WHERE ref_type IS NOT NULL;
CREATE INDEX admin_message_time ON src.src_msg_loop_admin_message (create_time);
COMMENT ON TABLE src.src_msg_loop_admin_message IS '管理端站内信：商户员工、平台人员收到的通知（每个收件人一行，保留 180 天）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.id IS '消息ID';
COMMENT ON COLUMN src.src_msg_loop_admin_message.admin_id IS '收件人（管理端账号ID）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.category_type IS '分类：product-商品（审核结果、下架、平台退款） promotion-官方活动（邀请、报名、移出） settlement-结算单 openapi-开放平台（应用停用启用、Webhook 推送失败） review-待审核（平台审核人员） system-系统通知';
COMMENT ON COLUMN src.src_msg_loop_admin_message.level_type IS '级别：info-通知 success-成功 warning-需注意 error-异常';
COMMENT ON COLUMN src.src_msg_loop_admin_message.title IS '标题（最多 80 字）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.body_text IS '正文（最多 300 字，可为空）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.link_url IS '点击后跳转的管理端页面路径（如 /merchant/products?id=31），为空不跳转';
COMMENT ON COLUMN src.src_msg_loop_admin_message.is_read IS '是否已读';
COMMENT ON COLUMN src.src_msg_loop_admin_message.read_time IS '读取时间（未读为空）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.ref_type IS '来源对象类型：product-商品 promotion_entry-活动条目 product_order-商品订单 statement-结算单 open_app-开放平台应用 open_app_webhook-应用的 Webhook 推送失败（同一应用 24 小时内只发一条）；可为空';
COMMENT ON COLUMN src.src_msg_loop_admin_message.ref_id IS '来源对象ID（与 ref_type 对应，可为空）';
COMMENT ON COLUMN src.src_msg_loop_admin_message.create_time IS '发送时间';
