DELETE FROM src.src_cnt_loop_review_task WHERE target_type = 'product';
ALTER TABLE src.src_cnt_loop_review_task DROP CONSTRAINT IF EXISTS src_cnt_loop_review_task_target_type_check;
ALTER TABLE src.src_cnt_loop_review_task ADD CONSTRAINT src_cnt_loop_review_task_target_type_check
    CHECK (target_type IN ('post', 'comment', 'nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio', 'meetup'));

DELETE FROM src.src_fin_loop_statement_line WHERE line_type = 'product';
ALTER TABLE src.src_fin_loop_statement_line DROP COLUMN IF EXISTS subsidy_amt;
ALTER TABLE src.src_fin_loop_statement_line DROP CONSTRAINT IF EXISTS src_fin_loop_statement_line_line_type_check;
ALTER TABLE src.src_fin_loop_statement_line ADD CONSTRAINT src_fin_loop_statement_line_line_type_check CHECK (line_type IN ('redemption', 'booking'));
ALTER TABLE src.src_fin_loop_statement DROP COLUMN IF EXISTS product_qty, DROP COLUMN IF EXISTS product_amt,
    DROP COLUMN IF EXISTS product_commission_rate, DROP COLUMN IF EXISTS product_commission_amt, DROP COLUMN IF EXISTS product_subsidy_amt;

DELETE FROM src.src_mer_loop_redemption WHERE redemption_type = 'product';
ALTER TABLE src.src_mer_loop_redemption DROP CONSTRAINT IF EXISTS redemption_type_ref;
ALTER TABLE src.src_mer_loop_redemption DROP CONSTRAINT IF EXISTS redemption_operator;
DROP INDEX IF EXISTS src.redemption_product_order;
DROP INDEX IF EXISTS src.redemption_coupon;
ALTER TABLE src.src_mer_loop_redemption DROP COLUMN IF EXISTS redemption_type, DROP COLUMN IF EXISTS product_id, DROP COLUMN IF EXISTS product_order_id,
    DROP COLUMN IF EXISTS promotion_id, DROP COLUMN IF EXISTS product_amt, DROP COLUMN IF EXISTS product_subsidy_amt, DROP COLUMN IF EXISTS open_app_id;
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN admin_id SET NOT NULL;
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN activity_id SET NOT NULL;
ALTER TABLE src.src_mer_loop_redemption ALTER COLUMN drop_id SET NOT NULL;
ALTER TABLE src.src_mer_loop_redemption ADD CONSTRAINT src_mer_loop_redemption_coupon_id_key UNIQUE (coupon_id);

DELETE FROM src.src_mkt_loop_coupon WHERE source_type = 'product';
ALTER TABLE src.src_mkt_loop_coupon DROP CONSTRAINT IF EXISTS coupon_source_ref;
DROP INDEX IF EXISTS src.coupon_product_order;
ALTER TABLE src.src_mkt_loop_coupon DROP COLUMN IF EXISTS product_id, DROP COLUMN IF EXISTS product_order_id, DROP COLUMN IF EXISTS use_qty,
    DROP COLUMN IF EXISTS left_use_qty, DROP COLUMN IF EXISTS paid_amt, DROP COLUMN IF EXISTS platform_subsidy_amt, DROP COLUMN IF EXISTS is_refundable,
    DROP COLUMN IF EXISTS venue_ids, DROP COLUMN IF EXISTS refund_id, DROP COLUMN IF EXISTS refund_time;
UPDATE src.src_mkt_loop_coupon SET coupon_status = 'expired' WHERE coupon_status = 'refunded';
ALTER TABLE src.src_mkt_loop_coupon DROP CONSTRAINT IF EXISTS src_mkt_loop_coupon_coupon_status_check;
ALTER TABLE src.src_mkt_loop_coupon ADD CONSTRAINT src_mkt_loop_coupon_coupon_status_check CHECK (coupon_status IN ('unused', 'used', 'expired', 'voided'));
ALTER TABLE src.src_mkt_loop_coupon DROP CONSTRAINT IF EXISTS src_mkt_loop_coupon_source_type_check;
ALTER TABLE src.src_mkt_loop_coupon ADD CONSTRAINT src_mkt_loop_coupon_source_type_check CHECK (source_type IN ('supply', 'chest', 'stronghold'));
ALTER TABLE src.src_mkt_loop_coupon ALTER COLUMN drop_id SET NOT NULL;

DROP TABLE IF EXISTS src.src_ord_loop_product_refund;
DROP TABLE IF EXISTS src.src_ord_loop_product_order;
DELETE FROM src.src_ord_loop_order WHERE biz_type = 'product';
ALTER TABLE src.src_ord_loop_order DROP CONSTRAINT IF EXISTS src_ord_loop_order_biz_type_check;
ALTER TABLE src.src_ord_loop_order ADD CONSTRAINT src_ord_loop_order_biz_type_check CHECK (biz_type IN ('membership', 'booking', 'race_fee'));

DROP TABLE IF EXISTS src.src_mkt_loop_promotion_entry;
DROP TABLE IF EXISTS src.src_mkt_loop_promotion;
DROP TABLE IF EXISTS src.src_mer_loop_product;
ALTER TABLE src.src_mer_loop_merchant DROP COLUMN IF EXISTS product_commission_rate;
