COMMENT ON TABLE src.src_mkt_loop_race_entry IS '赛事报名与成绩（开始前取消报名即删除）';
ALTER TABLE src.src_mkt_loop_race_entry DROP COLUMN IF EXISTS order_no;
DELETE FROM src.src_mkt_loop_race_entry WHERE entry_status = 'pending_pay';
ALTER TABLE src.src_mkt_loop_race_entry DROP CONSTRAINT IF EXISTS src_mkt_loop_race_entry_entry_status_check;
ALTER TABLE src.src_mkt_loop_race_entry ADD CONSTRAINT src_mkt_loop_race_entry_entry_status_check CHECK (entry_status IN ('signed', 'finished'));
COMMENT ON COLUMN src.src_mkt_loop_race_entry.entry_status IS '报名状态：signed-已报名 finished-已完赛（赛事结束仍为 signed 的，接口显示为 dnf-未完赛）';
ALTER TABLE src.src_mkt_loop_race DROP COLUMN IF EXISTS fee_amt;

DROP TABLE IF EXISTS src.src_ord_loop_booking;

DELETE FROM src.src_ord_loop_order WHERE biz_type <> 'membership';
ALTER TABLE src.src_ord_loop_order DROP CONSTRAINT IF EXISTS order_biz_ref;
DROP INDEX IF EXISTS src.orders_biz;
ALTER TABLE src.src_ord_loop_order DROP COLUMN IF EXISTS biz_id, DROP COLUMN IF EXISTS biz_type;
ALTER TABLE src.src_ord_loop_order ALTER COLUMN plan_code SET NOT NULL;
COMMENT ON TABLE src.src_ord_loop_order IS '会员订单';
COMMENT ON COLUMN src.src_ord_loop_order.plan_code IS '套餐代码（src_ord_loop_plan.code）';
COMMENT ON COLUMN src.src_ord_loop_order.plan_name IS '下单时的套餐名称';

DROP TABLE IF EXISTS src.src_mer_loop_venue_owner;
DROP TABLE IF EXISTS src.src_mer_loop_venue_checkin;
DROP TABLE IF EXISTS src.src_mer_loop_venue;
