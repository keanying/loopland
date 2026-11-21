-- 社区内容（V2 第二批「社区」A 部分）：关注、拉黑、动态、评论、点赞、收藏、跑团邀请码、举报

ALTER TABLE src.src_usr_loop_user ADD COLUMN bio TEXT;
COMMENT ON COLUMN src.src_usr_loop_user.bio IS '个人简介（≤ 60 字，先生效后审核，审核拒绝时清空）';

CREATE TABLE src.src_soc_loop_follow (
    follower_id     BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    followee_id     BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id),
    CHECK (follower_id <> followee_id)
);
CREATE INDEX follow_followee ON src.src_soc_loop_follow (followee_id, create_time DESC);
COMMENT ON TABLE src.src_soc_loop_follow IS '关注关系：一行表示 follower 关注了 followee';
COMMENT ON COLUMN src.src_soc_loop_follow.follower_id IS '关注者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_follow.followee_id IS '被关注者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_follow.create_time IS '关注时间';

CREATE TABLE src.src_soc_loop_block (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    blocked_user_id BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, blocked_user_id),
    CHECK (user_id <> blocked_user_id)
);
CREATE INDEX block_blocked ON src.src_soc_loop_block (blocked_user_id);
COMMENT ON TABLE src.src_soc_loop_block IS '拉黑关系：一行表示 user 拉黑了 blocked_user；双方互相看不到动态和评论、不能关注和私信';
COMMENT ON COLUMN src.src_soc_loop_block.user_id IS '拉黑者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_block.blocked_user_id IS '被拉黑者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_block.create_time IS '拉黑时间';

CREATE TABLE src.src_soc_loop_post (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    content_text    TEXT        NOT NULL DEFAULT '',
    images_json     JSONB       NOT NULL DEFAULT '[]',
    activity_id     BIGINT      REFERENCES src.src_act_loop_activity (id) ON DELETE SET NULL,
    visibility_type TEXT        NOT NULL DEFAULT 'public' CHECK (visibility_type IN ('public', 'fans', 'crew', 'private')),
    review_status   TEXT        NOT NULL DEFAULT 'approved' CHECK (review_status IN ('pending', 'approved', 'rejected')),
    reject_reason   TEXT,
    like_qty        INT         NOT NULL DEFAULT 0 CHECK (like_qty >= 0),
    comment_qty     INT         NOT NULL DEFAULT 0 CHECK (comment_qty >= 0),
    collect_qty     INT         NOT NULL DEFAULT 0 CHECK (collect_qty >= 0),
    share_qty       INT         NOT NULL DEFAULT 0 CHECK (share_qty >= 0),
    report_qty      INT         NOT NULL DEFAULT 0 CHECK (report_qty >= 0),
    delete_time     TIMESTAMPTZ,
    delete_reason   TEXT,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX post_user_time ON src.src_soc_loop_post (user_id, create_time DESC, id DESC);
CREATE INDEX post_public_time ON src.src_soc_loop_post (create_time DESC, id DESC)
    WHERE delete_time IS NULL AND review_status = 'approved' AND visibility_type = 'public';
CREATE INDEX post_activity ON src.src_soc_loop_post (activity_id) WHERE activity_id IS NOT NULL;
COMMENT ON TABLE src.src_soc_loop_post IS '动态：文字、图片、可附一次运动；按可见范围和审核状态展示';
COMMENT ON COLUMN src.src_soc_loop_post.id IS '动态ID';
COMMENT ON COLUMN src.src_soc_loop_post.user_id IS '作者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_post.content_text IS '正文（≤ 500 字，有图片或运动时可为空）';
COMMENT ON COLUMN src.src_soc_loop_post.images_json IS '图片列表（JSON 数组，元素 {id,url,width,height}，id 为 src_cnt_loop_media 的图片ID，最多 9 张）';
COMMENT ON COLUMN src.src_soc_loop_post.activity_id IS '附带的运动记录ID（作者本人已结算的运动；没附为空）';
COMMENT ON COLUMN src.src_soc_loop_post.visibility_type IS '可见范围：public-公开 fans-仅粉丝（关注作者的人） crew-仅跑团（与作者同一跑团的成员） private-仅自己';
COMMENT ON COLUMN src.src_soc_loop_post.review_status IS '审核状态：pending-待审核（只有作者能看到） approved-已通过 rejected-未通过（只有作者能看到，带原因）';
COMMENT ON COLUMN src.src_soc_loop_post.reject_reason IS '审核拒绝原因（发给作者）';
COMMENT ON COLUMN src.src_soc_loop_post.like_qty IS '点赞数';
COMMENT ON COLUMN src.src_soc_loop_post.comment_qty IS '评论数（已通过、未删除的评论和回复）';
COMMENT ON COLUMN src.src_soc_loop_post.collect_qty IS '收藏数';
COMMENT ON COLUMN src.src_soc_loop_post.share_qty IS '分享次数';
COMMENT ON COLUMN src.src_soc_loop_post.report_qty IS '被不同用户举报的次数';
COMMENT ON COLUMN src.src_soc_loop_post.delete_time IS '删除时间（作者删除或管理端下架；未删除为空）';
COMMENT ON COLUMN src.src_soc_loop_post.delete_reason IS '删除原因：作者删除为空，管理端下架时为下架原因';
COMMENT ON COLUMN src.src_soc_loop_post.create_time IS '发布时间';
COMMENT ON COLUMN src.src_soc_loop_post.update_time IS '最后修改时间';

CREATE TABLE src.src_soc_loop_post_like (
    post_id         BIGINT      NOT NULL REFERENCES src.src_soc_loop_post (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, user_id)
);
CREATE INDEX post_like_user ON src.src_soc_loop_post_like (user_id);
COMMENT ON TABLE src.src_soc_loop_post_like IS '动态点赞';
COMMENT ON COLUMN src.src_soc_loop_post_like.post_id IS '动态ID';
COMMENT ON COLUMN src.src_soc_loop_post_like.user_id IS '点赞的用户ID';
COMMENT ON COLUMN src.src_soc_loop_post_like.create_time IS '点赞时间';

CREATE TABLE src.src_soc_loop_post_collect (
    post_id         BIGINT      NOT NULL REFERENCES src.src_soc_loop_post (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (post_id, user_id)
);
CREATE INDEX post_collect_user ON src.src_soc_loop_post_collect (user_id, create_time DESC, post_id DESC);
COMMENT ON TABLE src.src_soc_loop_post_collect IS '动态收藏';
COMMENT ON COLUMN src.src_soc_loop_post_collect.post_id IS '动态ID';
COMMENT ON COLUMN src.src_soc_loop_post_collect.user_id IS '收藏的用户ID';
COMMENT ON COLUMN src.src_soc_loop_post_collect.create_time IS '收藏时间';

CREATE TABLE src.src_soc_loop_comment (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    post_id         BIGINT      NOT NULL REFERENCES src.src_soc_loop_post (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    parent_id       BIGINT      REFERENCES src.src_soc_loop_comment (id) ON DELETE CASCADE,
    reply_to_user_id BIGINT     REFERENCES src.src_usr_loop_user (id) ON DELETE SET NULL,
    content_text    TEXT        NOT NULL,
    review_status   TEXT        NOT NULL DEFAULT 'approved' CHECK (review_status IN ('pending', 'approved', 'rejected')),
    reject_reason   TEXT,
    like_qty        INT         NOT NULL DEFAULT 0 CHECK (like_qty >= 0),
    reply_qty       INT         NOT NULL DEFAULT 0 CHECK (reply_qty >= 0),
    report_qty      INT         NOT NULL DEFAULT 0 CHECK (report_qty >= 0),
    approve_time    TIMESTAMPTZ,
    delete_time     TIMESTAMPTZ,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX comment_post_top ON src.src_soc_loop_comment (post_id, create_time, id) WHERE parent_id IS NULL;
CREATE INDEX comment_parent ON src.src_soc_loop_comment (parent_id, create_time, id) WHERE parent_id IS NOT NULL;
CREATE INDEX comment_user ON src.src_soc_loop_comment (user_id);
COMMENT ON TABLE src.src_soc_loop_comment IS '动态评论：两级（一级评论 + 回复）';
COMMENT ON COLUMN src.src_soc_loop_comment.id IS '评论ID';
COMMENT ON COLUMN src.src_soc_loop_comment.post_id IS '所属动态ID';
COMMENT ON COLUMN src.src_soc_loop_comment.user_id IS '评论作者（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_comment.parent_id IS '所属一级评论ID（一级评论为空，回复为它所在的一级评论）';
COMMENT ON COLUMN src.src_soc_loop_comment.reply_to_user_id IS '被回复的用户ID（回复某条回复时为那条回复的作者；一级评论和直接回复一级评论时为空）';
COMMENT ON COLUMN src.src_soc_loop_comment.content_text IS '评论内容（1–200 字）';
COMMENT ON COLUMN src.src_soc_loop_comment.review_status IS '审核状态：pending-待审核（只有作者能看到） approved-已通过 rejected-未通过（只有作者能看到）';
COMMENT ON COLUMN src.src_soc_loop_comment.reject_reason IS '审核拒绝原因';
COMMENT ON COLUMN src.src_soc_loop_comment.like_qty IS '点赞数';
COMMENT ON COLUMN src.src_soc_loop_comment.reply_qty IS '回复数（一级评论下已通过、未删除的回复；回复本身为 0）';
COMMENT ON COLUMN src.src_soc_loop_comment.report_qty IS '被不同用户举报的次数';
COMMENT ON COLUMN src.src_soc_loop_comment.approve_time IS '首次通过审核的时间（用于只发一次互动通知；未通过过为空）';
COMMENT ON COLUMN src.src_soc_loop_comment.delete_time IS '删除时间（评论作者、动态作者删除或管理端下架；未删除为空）';
COMMENT ON COLUMN src.src_soc_loop_comment.create_time IS '评论时间';
COMMENT ON COLUMN src.src_soc_loop_comment.update_time IS '最后修改时间';

CREATE TABLE src.src_soc_loop_comment_like (
    comment_id      BIGINT      NOT NULL REFERENCES src.src_soc_loop_comment (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (comment_id, user_id)
);
CREATE INDEX comment_like_user ON src.src_soc_loop_comment_like (user_id);
COMMENT ON TABLE src.src_soc_loop_comment_like IS '评论点赞';
COMMENT ON COLUMN src.src_soc_loop_comment_like.comment_id IS '评论ID';
COMMENT ON COLUMN src.src_soc_loop_comment_like.user_id IS '点赞的用户ID';
COMMENT ON COLUMN src.src_soc_loop_comment_like.create_time IS '点赞时间';

CREATE TABLE src.src_soc_loop_crew_invite (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    crew_id         BIGINT      NOT NULL REFERENCES src.src_soc_loop_crew (id) ON DELETE CASCADE,
    invite_code     TEXT        NOT NULL UNIQUE,
    creator_id      BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    expire_time     TIMESTAMPTZ NOT NULL,
    use_qty         INT         NOT NULL DEFAULT 0,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX crew_invite_crew ON src.src_soc_loop_crew_invite (crew_id);
COMMENT ON TABLE src.src_soc_loop_crew_invite IS '跑团邀请码：团长生成，7 天有效，可多次使用；凭码加入不受加入方式限制';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.id IS '邀请码记录ID';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.crew_id IS '跑团ID';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.invite_code IS '邀请码（6 位大写字母和数字，去掉易混的 0/O/1/I）';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.creator_id IS '生成邀请码的团长（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.use_qty IS '已通过此码加入的人数';
COMMENT ON COLUMN src.src_soc_loop_crew_invite.create_time IS '生成时间';

CREATE TABLE src.src_cnt_loop_report (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reporter_id     BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    target_type     TEXT        NOT NULL CHECK (target_type IN ('post', 'comment', 'user', 'crew', 'message')),
    target_id       BIGINT      NOT NULL,
    reason_type     TEXT        NOT NULL CHECK (reason_type IN ('spam', 'porn', 'abuse', 'fraud', 'illegal', 'other')),
    detail_text     TEXT,
    report_status   TEXT        NOT NULL DEFAULT 'pending' CHECK (report_status IN ('pending', 'handled', 'dismissed')),
    handle_action_type TEXT     CHECK (handle_action_type IN ('remove', 'dismiss')),
    handler_id      BIGINT      REFERENCES src.src_sys_loop_admin (id),
    handle_note     TEXT,
    mute_day_qty    INT         NOT NULL DEFAULT 0,
    handle_time     TIMESTAMPTZ,
    create_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (reporter_id, target_type, target_id)
);
CREATE INDEX report_queue ON src.src_cnt_loop_report (report_status, create_time);
CREATE INDEX report_target ON src.src_cnt_loop_report (target_type, target_id);
COMMENT ON TABLE src.src_cnt_loop_report IS '用户举报：同一人对同一对象只能举报一次；管理端举报处理';
COMMENT ON COLUMN src.src_cnt_loop_report.id IS '举报ID';
COMMENT ON COLUMN src.src_cnt_loop_report.reporter_id IS '举报人（用户ID）';
COMMENT ON COLUMN src.src_cnt_loop_report.target_type IS '举报对象类型：post-动态 comment-评论 user-用户 crew-跑团 message-私信/群聊消息';
COMMENT ON COLUMN src.src_cnt_loop_report.target_id IS '举报对象ID（按 target_type 分别为动态/评论/用户/跑团/消息的ID）';
COMMENT ON COLUMN src.src_cnt_loop_report.reason_type IS '举报原因：spam-垃圾广告 porn-色情低俗 abuse-辱骂攻击 fraud-诈骗 illegal-违法违规 other-其他';
COMMENT ON COLUMN src.src_cnt_loop_report.detail_text IS '补充说明（≤ 200 字，可空）';
COMMENT ON COLUMN src.src_cnt_loop_report.report_status IS '处理状态：pending-待处理 handled-已处理（对象已下架） dismissed-已驳回（不处理）';
COMMENT ON COLUMN src.src_cnt_loop_report.handle_action_type IS '处理动作：remove-下架对象 dismiss-驳回；未处理为空';
COMMENT ON COLUMN src.src_cnt_loop_report.handler_id IS '处理人（后台管理员ID）';
COMMENT ON COLUMN src.src_cnt_loop_report.handle_note IS '处理备注（管理端内部）';
COMMENT ON COLUMN src.src_cnt_loop_report.mute_day_qty IS '处理时对作者禁言的天数（0 表示不禁言）';
COMMENT ON COLUMN src.src_cnt_loop_report.handle_time IS '处理时间';
COMMENT ON COLUMN src.src_cnt_loop_report.create_time IS '举报时间';
