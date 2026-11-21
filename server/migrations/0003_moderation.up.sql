-- 内容审核：审核任务队列（V2 第二批「社区」）
CREATE TABLE src.src_cnt_loop_review_task (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_type     TEXT        NOT NULL CHECK (target_type IN ('post', 'comment', 'nickname', 'avatar', 'crew_name', 'crew_avatar', 'bio', 'meetup')),
    target_id       BIGINT      NOT NULL,
    user_id         BIGINT      REFERENCES src.src_usr_loop_user (id) ON DELETE SET NULL,
    content_text    TEXT,
    images_json     JSONB       NOT NULL DEFAULT '[]',
    risk_score      INT         NOT NULL DEFAULT 0 CHECK (risk_score BETWEEN 0 AND 100),
    risk_reasons_json JSONB     NOT NULL DEFAULT '[]',
    report_qty      INT         NOT NULL DEFAULT 0,
    review_status   TEXT        NOT NULL DEFAULT 'pending' CHECK (review_status IN ('pending', 'approved', 'rejected')),
    reject_reason   TEXT,
    reviewer_id     BIGINT      REFERENCES src.src_sys_loop_admin (id),
    review_time     TIMESTAMPTZ,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX review_task_pending ON src.src_cnt_loop_review_task (target_type, target_id) WHERE review_status = 'pending';
CREATE INDEX review_task_queue ON src.src_cnt_loop_review_task (review_status, risk_score DESC, create_time);
COMMENT ON TABLE src.src_cnt_loop_review_task IS '内容审核任务：动态、评论、昵称、头像、跑团名称/头像、简介、组局；管理端审核队列';
COMMENT ON COLUMN src.src_cnt_loop_review_task.id IS '审核任务ID';
COMMENT ON COLUMN src.src_cnt_loop_review_task.target_type IS '审核对象类型：post-动态 comment-评论 nickname-用户昵称 avatar-用户头像 crew_name-跑团名称 crew_avatar-跑团头像 bio-个人简介 meetup-组局';
COMMENT ON COLUMN src.src_cnt_loop_review_task.target_id IS '审核对象ID：动态/评论/组局为各自ID，昵称/头像/简介为用户ID，跑团名称/头像为跑团ID';
COMMENT ON COLUMN src.src_cnt_loop_review_task.user_id IS '内容作者（用户ID）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.content_text IS '送审文本（正文、新昵称、新名称等）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.images_json IS '送审图片地址列表（JSON 数组）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.risk_score IS '风险分 0-100：越高越可疑；按敏感词、联系方式、新用户等规则打分';
COMMENT ON COLUMN src.src_cnt_loop_review_task.risk_reasons_json IS '风险原因列表（JSON 数组，中文说明，不含敏感词原文）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.report_qty IS '该对象被举报次数';
COMMENT ON COLUMN src.src_cnt_loop_review_task.review_status IS '审核状态：pending-待审核 approved-通过 rejected-拒绝';
COMMENT ON COLUMN src.src_cnt_loop_review_task.reject_reason IS '拒绝原因（发给作者）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.reviewer_id IS '审核人（后台管理员ID）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.review_time IS '审核时间';
COMMENT ON COLUMN src.src_cnt_loop_review_task.create_time IS '送审时间';
