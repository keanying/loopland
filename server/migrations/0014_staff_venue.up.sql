-- 商户员工绑定门店（V2 第六批之后：核销门店校验）
CREATE TABLE src.src_mer_loop_staff_venue (
    admin_id     BIGINT      NOT NULL REFERENCES src.src_sys_loop_admin (id) ON DELETE CASCADE,
    venue_id     BIGINT      NOT NULL REFERENCES src.src_mer_loop_venue (id) ON DELETE CASCADE,
    create_time  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (admin_id, venue_id)
);
CREATE INDEX staff_venue_venue ON src.src_mer_loop_staff_venue (venue_id);
COMMENT ON TABLE src.src_mer_loop_staff_venue IS '商户员工绑定的门店：绑定后该员工只能核销适用于这些门店的商品券，核销门店默认取绑定的门店；不绑定则不限门店';
COMMENT ON COLUMN src.src_mer_loop_staff_venue.admin_id IS '员工账号（管理端账号ID，角色为 merchant）';
COMMENT ON COLUMN src.src_mer_loop_staff_venue.venue_id IS '门店（场馆ID，须属于该员工所在商户）';
COMMENT ON COLUMN src.src_mer_loop_staff_venue.create_time IS '绑定时间';
