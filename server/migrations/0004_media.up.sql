-- 用户上传的图片（动态、头像、跑团头像、聊天）
CREATE TABLE src.src_cnt_loop_media (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    purpose_type    TEXT        NOT NULL CHECK (purpose_type IN ('post', 'avatar', 'crew_avatar', 'chat')),
    storage_type    TEXT        NOT NULL CHECK (storage_type IN ('local', 'oss')),
    object_key      TEXT        NOT NULL UNIQUE,
    url             TEXT        NOT NULL,
    content_type    TEXT        NOT NULL,
    size_byte_qty   BIGINT      NOT NULL,
    width_px        INT,
    height_px       INT,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX media_user_day ON src.src_cnt_loop_media (user_id, create_time);
COMMENT ON TABLE src.src_cnt_loop_media IS '用户上传的图片：动态、头像、跑团头像、聊天图片';
COMMENT ON COLUMN src.src_cnt_loop_media.id IS '图片ID';
COMMENT ON COLUMN src.src_cnt_loop_media.user_id IS '上传者（用户ID）';
COMMENT ON COLUMN src.src_cnt_loop_media.purpose_type IS '用途：post-动态图片 avatar-用户头像 crew_avatar-跑团头像 chat-聊天图片';
COMMENT ON COLUMN src.src_cnt_loop_media.storage_type IS '存储位置：local-本机磁盘（开发环境） oss-阿里云对象存储';
COMMENT ON COLUMN src.src_cnt_loop_media.object_key IS '存储里的对象路径，如 post/2026/11/21/<随机>.jpg';
COMMENT ON COLUMN src.src_cnt_loop_media.url IS '访问地址';
COMMENT ON COLUMN src.src_cnt_loop_media.content_type IS 'MIME 类型：image/jpeg、image/png、image/webp、image/heic';
COMMENT ON COLUMN src.src_cnt_loop_media.size_byte_qty IS '文件大小（字节）';
COMMENT ON COLUMN src.src_cnt_loop_media.width_px IS '图片宽度（像素，无法识别时为空）';
COMMENT ON COLUMN src.src_cnt_loop_media.height_px IS '图片高度（像素，无法识别时为空）';
COMMENT ON COLUMN src.src_cnt_loop_media.create_time IS '上传时间';
