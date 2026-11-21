DROP TABLE IF EXISTS src.src_ply_loop_user_item;
DROP TABLE IF EXISTS src.src_ply_loop_shop_item;
DROP TABLE IF EXISTS src.src_fin_loop_statement_line;
DROP TABLE IF EXISTS src.src_fin_loop_statement;
DROP TABLE IF EXISTS src.src_mer_loop_redemption;
DROP TABLE IF EXISTS src.src_mkt_loop_coupon;
ALTER TABLE src.src_ply_loop_chest DROP COLUMN IF EXISTS drop_id;
DROP TABLE IF EXISTS src.src_mer_loop_drop;
DROP TABLE IF EXISTS src.src_mkt_loop_brand_campaign;
