-- V2 第二批「社区」：私信与群聊、组局、集结跑、赛事（docs/api/v2-2-社区.md）

-- ---------------------------------------------------------------- 私信与群聊
CREATE TABLE src.src_msg_loop_conversation (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_type   TEXT        NOT NULL CHECK (conversation_type IN ('direct', 'group')),
    direct_key          TEXT        UNIQUE,
    title               TEXT,
    avatar_url          TEXT,
    ref_type            TEXT        CHECK (ref_type IN ('meetup', 'rally')),
    ref_id              BIGINT,
    last_message_id     BIGINT,
    last_message_time   TIMESTAMPTZ,
    create_time         TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time         TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((conversation_type = 'direct') = (direct_key IS NOT NULL))
);
CREATE UNIQUE INDEX conversation_ref ON src.src_msg_loop_conversation (ref_type, ref_id) WHERE ref_type IS NOT NULL;
COMMENT ON TABLE src.src_msg_loop_conversation IS '会话：私信（两人）和群聊（组局、集结跑）';
COMMENT ON COLUMN src.src_msg_loop_conversation.id IS '会话ID';
COMMENT ON COLUMN src.src_msg_loop_conversation.conversation_type IS '会话类型：direct-私信 group-群聊';
COMMENT ON COLUMN src.src_msg_loop_conversation.direct_key IS '私信唯一键「小用户ID:大用户ID」，保证两人之间只有一个私信会话；群聊为空';
COMMENT ON COLUMN src.src_msg_loop_conversation.title IS '群聊名称（取组局/集结跑标题）；私信为空，显示对方昵称';
COMMENT ON COLUMN src.src_msg_loop_conversation.avatar_url IS '群聊头像地址；私信为空，显示对方头像';
COMMENT ON COLUMN src.src_msg_loop_conversation.ref_type IS '群聊来源类型：meetup-组局 rally-集结跑；私信为空';
COMMENT ON COLUMN src.src_msg_loop_conversation.ref_id IS '群聊来源ID（组局ID或集结跑ID）';
COMMENT ON COLUMN src.src_msg_loop_conversation.last_message_id IS '最后一条消息ID';
COMMENT ON COLUMN src.src_msg_loop_conversation.last_message_time IS '最后一条消息时间（会话列表按它倒序）';
COMMENT ON COLUMN src.src_msg_loop_conversation.create_time IS '创建时间';
COMMENT ON COLUMN src.src_msg_loop_conversation.update_time IS '更新时间';

CREATE TABLE src.src_msg_loop_conv_member (
    conversation_id       BIGINT      NOT NULL REFERENCES src.src_msg_loop_conversation (id) ON DELETE CASCADE,
    user_id               BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    member_role_type      TEXT        NOT NULL DEFAULT 'member' CHECK (member_role_type IN ('owner', 'member')),
    last_read_message_id  BIGINT      NOT NULL DEFAULT 0,
    is_muted              BOOLEAN     NOT NULL DEFAULT false,
    is_hidden             BOOLEAN     NOT NULL DEFAULT false,
    join_time             TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX conv_member_user ON src.src_msg_loop_conv_member (user_id);
COMMENT ON TABLE src.src_msg_loop_conv_member IS '会话成员：私信双方、群聊成员（退群即删除）';
COMMENT ON COLUMN src.src_msg_loop_conv_member.conversation_id IS '会话ID';
COMMENT ON COLUMN src.src_msg_loop_conv_member.user_id IS '成员（用户ID）';
COMMENT ON COLUMN src.src_msg_loop_conv_member.member_role_type IS '成员角色：owner-群主（组局/集结跑发起人） member-普通成员';
COMMENT ON COLUMN src.src_msg_loop_conv_member.last_read_message_id IS '已读到的消息ID（之后别人发的消息算未读）';
COMMENT ON COLUMN src.src_msg_loop_conv_member.is_muted IS '是否免打扰（免打扰的会话不计入消息总未读数）';
COMMENT ON COLUMN src.src_msg_loop_conv_member.is_hidden IS '是否从会话列表隐藏（私信删除后隐藏，有新消息时恢复）';
COMMENT ON COLUMN src.src_msg_loop_conv_member.join_time IS '加入时间';

CREATE TABLE src.src_msg_loop_message (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversation_id  BIGINT      NOT NULL REFERENCES src.src_msg_loop_conversation (id) ON DELETE CASCADE,
    sender_id        BIGINT      REFERENCES src.src_usr_loop_user (id) ON DELETE SET NULL,
    message_type     TEXT        NOT NULL CHECK (message_type IN ('text', 'image', 'post', 'system')),
    content          TEXT        NOT NULL DEFAULT '',
    payload_json     JSONB       NOT NULL DEFAULT '{}',
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX message_conversation ON src.src_msg_loop_message (conversation_id, id DESC);
COMMENT ON TABLE src.src_msg_loop_message IS '会话消息（私信、群聊）';
COMMENT ON COLUMN src.src_msg_loop_message.id IS '消息ID';
COMMENT ON COLUMN src.src_msg_loop_message.conversation_id IS '会话ID';
COMMENT ON COLUMN src.src_msg_loop_message.sender_id IS '发送者（用户ID）；系统消息为空';
COMMENT ON COLUMN src.src_msg_loop_message.message_type IS '消息类型：text-文字 image-图片 post-分享动态 system-系统消息（进群、退群等）';
COMMENT ON COLUMN src.src_msg_loop_message.content IS '文字内容（文字消息、系统消息）';
COMMENT ON COLUMN src.src_msg_loop_message.payload_json IS '附加内容：图片 {url,width,height}，分享动态 {post_id}';
COMMENT ON COLUMN src.src_msg_loop_message.create_time IS '发送时间';

-- ---------------------------------------------------------------- 组局
CREATE TABLE src.src_soc_loop_meetup (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meetup_type      TEXT        NOT NULL CHECK (meetup_type IN ('run', 'ball', 'ride')),
    title            TEXT        NOT NULL,
    description      TEXT        NOT NULL DEFAULT '',
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ NOT NULL,
    place_name       TEXT        NOT NULL,
    place_geom       GEOMETRY(Point, 4326) NOT NULL,
    district         TEXT,
    capacity_qty     INT         NOT NULL CHECK (capacity_qty BETWEEN 2 AND 50),
    requirement      TEXT        NOT NULL DEFAULT '',
    creator_id       BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    meetup_status    TEXT        NOT NULL DEFAULT 'open' CHECK (meetup_status IN ('open', 'cancelled', 'ended')),
    review_status    TEXT        NOT NULL DEFAULT 'approved' CHECK (review_status IN ('pending', 'approved', 'rejected')),
    cancel_reason    TEXT,
    conversation_id  BIGINT      REFERENCES src.src_msg_loop_conversation (id) ON DELETE SET NULL,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time)
);
CREATE INDEX meetup_start ON src.src_soc_loop_meetup (start_time) WHERE meetup_status = 'open';
CREATE INDEX meetup_place ON src.src_soc_loop_meetup USING GIST ((place_geom::geography));
CREATE INDEX meetup_creator ON src.src_soc_loop_meetup (creator_id);
COMMENT ON TABLE src.src_soc_loop_meetup IS '组局：约跑、约球、约骑';
COMMENT ON COLUMN src.src_soc_loop_meetup.id IS '组局ID';
COMMENT ON COLUMN src.src_soc_loop_meetup.meetup_type IS '组局类型：run-约跑 ball-约球 ride-约骑';
COMMENT ON COLUMN src.src_soc_loop_meetup.title IS '标题（≤30 字，过审核）';
COMMENT ON COLUMN src.src_soc_loop_meetup.description IS '说明（≤300 字，过审核）';
COMMENT ON COLUMN src.src_soc_loop_meetup.start_time IS '开始时间';
COMMENT ON COLUMN src.src_soc_loop_meetup.end_time IS '结束时间（过了之后状态为 ended）';
COMMENT ON COLUMN src.src_soc_loop_meetup.place_name IS '集合地点名称';
COMMENT ON COLUMN src.src_soc_loop_meetup.place_geom IS '集合地点（GCJ-02，SRID 4326）';
COMMENT ON COLUMN src.src_soc_loop_meetup.district IS '所在城区（App 逆地理得到，可为空）';
COMMENT ON COLUMN src.src_soc_loop_meetup.capacity_qty IS '人数上限（含发起人，2-50）';
COMMENT ON COLUMN src.src_soc_loop_meetup.requirement IS '报名要求（如配速）';
COMMENT ON COLUMN src.src_soc_loop_meetup.creator_id IS '发起人（用户ID，群聊群主）';
COMMENT ON COLUMN src.src_soc_loop_meetup.meetup_status IS '组局状态：open-进行中（报名中或已满员，满员由人数计算） cancelled-已取消（发起人或运营取消、审核拒绝） ended-已结束（过了结束时间，定时任务写入）';
COMMENT ON COLUMN src.src_soc_loop_meetup.review_status IS '审核状态：pending-待审核（只有发起人能看到） approved-已通过 rejected-未通过';
COMMENT ON COLUMN src.src_soc_loop_meetup.cancel_reason IS '取消原因（运营取消、审核拒绝时填写）';
COMMENT ON COLUMN src.src_soc_loop_meetup.conversation_id IS '组局群聊（会话ID）';
COMMENT ON COLUMN src.src_soc_loop_meetup.create_time IS '创建时间';
COMMENT ON COLUMN src.src_soc_loop_meetup.update_time IS '更新时间';

CREATE TABLE src.src_soc_loop_meetup_join (
    meetup_id   BIGINT      NOT NULL REFERENCES src.src_soc_loop_meetup (id) ON DELETE CASCADE,
    user_id     BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    join_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (meetup_id, user_id)
);
CREATE INDEX meetup_join_user ON src.src_soc_loop_meetup_join (user_id);
COMMENT ON TABLE src.src_soc_loop_meetup_join IS '组局报名（退出即删除）';
COMMENT ON COLUMN src.src_soc_loop_meetup_join.meetup_id IS '组局ID';
COMMENT ON COLUMN src.src_soc_loop_meetup_join.user_id IS '报名人（用户ID，发起人也有一条）';
COMMENT ON COLUMN src.src_soc_loop_meetup_join.join_time IS '报名时间';

-- ---------------------------------------------------------------- 集结跑
CREATE TABLE src.src_soc_loop_rally (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    crew_id          BIGINT      NOT NULL REFERENCES src.src_soc_loop_crew (id) ON DELETE CASCADE,
    creator_id       BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    title            TEXT        NOT NULL,
    start_time       TIMESTAMPTZ NOT NULL,
    place_name       TEXT        NOT NULL,
    place_geom       GEOMETRY(Point, 4326) NOT NULL,
    distance_goal_m  DOUBLE PRECISION NOT NULL DEFAULT 0,
    rally_status     TEXT        NOT NULL DEFAULT 'open' CHECK (rally_status IN ('open', 'cancelled', 'ended')),
    conversation_id  BIGINT      REFERENCES src.src_msg_loop_conversation (id) ON DELETE SET NULL,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX rally_crew ON src.src_soc_loop_rally (crew_id, start_time DESC);
COMMENT ON TABLE src.src_soc_loop_rally IS '跑团集结跑：团长发起时间地点，成员报名、到场签到，签到满人数后运动有加成';
COMMENT ON COLUMN src.src_soc_loop_rally.id IS '集结跑ID';
COMMENT ON COLUMN src.src_soc_loop_rally.crew_id IS '跑团ID';
COMMENT ON COLUMN src.src_soc_loop_rally.creator_id IS '发起人（团长，用户ID）';
COMMENT ON COLUMN src.src_soc_loop_rally.title IS '标题';
COMMENT ON COLUMN src.src_soc_loop_rally.start_time IS '开始（集合）时间';
COMMENT ON COLUMN src.src_soc_loop_rally.place_name IS '集合地点名称';
COMMENT ON COLUMN src.src_soc_loop_rally.place_geom IS '集合地点（GCJ-02，SRID 4326）';
COMMENT ON COLUMN src.src_soc_loop_rally.distance_goal_m IS '目标距离（米，0 表示不设）';
COMMENT ON COLUMN src.src_soc_loop_rally.rally_status IS '集结跑状态：open-进行中 cancelled-已取消 ended-已结束（开始 3 小时后，定时任务写入）';
COMMENT ON COLUMN src.src_soc_loop_rally.conversation_id IS '集结跑群聊（会话ID）';
COMMENT ON COLUMN src.src_soc_loop_rally.create_time IS '创建时间';
COMMENT ON COLUMN src.src_soc_loop_rally.update_time IS '更新时间';

CREATE TABLE src.src_soc_loop_rally_join (
    rally_id      BIGINT      NOT NULL REFERENCES src.src_soc_loop_rally (id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    join_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    checkin_time  TIMESTAMPTZ,
    PRIMARY KEY (rally_id, user_id)
);
CREATE INDEX rally_join_user ON src.src_soc_loop_rally_join (user_id);
COMMENT ON TABLE src.src_soc_loop_rally_join IS '集结跑报名与签到（退出即删除）';
COMMENT ON COLUMN src.src_soc_loop_rally_join.rally_id IS '集结跑ID';
COMMENT ON COLUMN src.src_soc_loop_rally_join.user_id IS '报名成员（用户ID）';
COMMENT ON COLUMN src.src_soc_loop_rally_join.join_time IS '报名时间';
COMMENT ON COLUMN src.src_soc_loop_rally_join.checkin_time IS '到场签到时间（未签到为空）';

-- ---------------------------------------------------------------- 赛事
CREATE TABLE src.src_mkt_loop_race (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    race_type             TEXT        NOT NULL CHECK (race_type IN ('online', 'offline')),
    title                 TEXT        NOT NULL,
    cover_url             TEXT,
    description           TEXT        NOT NULL DEFAULT '',
    sport                 TEXT        NOT NULL,
    distance_m            DOUBLE PRECISION NOT NULL CHECK (distance_m > 0),
    start_time            TIMESTAMPTZ NOT NULL,
    end_time              TIMESTAMPTZ NOT NULL,
    signup_end_time       TIMESTAMPTZ NOT NULL,
    place_name            TEXT,
    place_geom            GEOMETRY(Point, 4326),
    capacity_qty          INT         NOT NULL CHECK (capacity_qty > 0),
    is_wearable_required  BOOLEAN     NOT NULL DEFAULT false,
    medal_key             TEXT        NOT NULL UNIQUE,
    medal_name            TEXT        NOT NULL,
    medal_image_url       TEXT,
    is_published          BOOLEAN     NOT NULL DEFAULT false,
    race_status           TEXT        NOT NULL DEFAULT 'normal' CHECK (race_status IN ('normal', 'cancelled')),
    created_by            BIGINT      REFERENCES src.src_sys_loop_admin (id),
    create_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_time > start_time AND signup_end_time <= end_time)
);
CREATE INDEX race_time ON src.src_mkt_loop_race (start_time DESC);
COMMENT ON TABLE src.src_mkt_loop_race IS '赛事：线上赛（时间窗内单次运动跑满距离即完赛）和线下赛（运营标记完赛）';
COMMENT ON COLUMN src.src_mkt_loop_race.id IS '赛事ID';
COMMENT ON COLUMN src.src_mkt_loop_race.race_type IS '赛事类型：online-线上赛 offline-线下赛';
COMMENT ON COLUMN src.src_mkt_loop_race.title IS '标题';
COMMENT ON COLUMN src.src_mkt_loop_race.cover_url IS '封面图地址';
COMMENT ON COLUMN src.src_mkt_loop_race.description IS '赛事说明';
COMMENT ON COLUMN src.src_mkt_loop_race.sport IS '运动类型：run-跑步 ride-骑行 hike-徒步 walk-健走';
COMMENT ON COLUMN src.src_mkt_loop_race.distance_m IS '赛事距离（米）';
COMMENT ON COLUMN src.src_mkt_loop_race.start_time IS '比赛开始时间（线上赛时间窗开始）';
COMMENT ON COLUMN src.src_mkt_loop_race.end_time IS '比赛结束时间（线上赛时间窗结束）';
COMMENT ON COLUMN src.src_mkt_loop_race.signup_end_time IS '报名截止时间';
COMMENT ON COLUMN src.src_mkt_loop_race.place_name IS '线下赛地点名称（线上赛为空）';
COMMENT ON COLUMN src.src_mkt_loop_race.place_geom IS '线下赛地点（GCJ-02，SRID 4326；线上赛为空）';
COMMENT ON COLUMN src.src_mkt_loop_race.capacity_qty IS '名额';
COMMENT ON COLUMN src.src_mkt_loop_race.is_wearable_required IS '线上赛是否要求运动带穿戴设备数据';
COMMENT ON COLUMN src.src_mkt_loop_race.medal_key IS '完赛奖牌标识（图鉴 medal 类的 item，全局唯一）';
COMMENT ON COLUMN src.src_mkt_loop_race.medal_name IS '完赛奖牌名称';
COMMENT ON COLUMN src.src_mkt_loop_race.medal_image_url IS '完赛奖牌图片地址';
COMMENT ON COLUMN src.src_mkt_loop_race.is_published IS '是否已发布（未发布的 App 看不到）';
COMMENT ON COLUMN src.src_mkt_loop_race.race_status IS '运营状态：normal-正常（展示状态按时间计算） cancelled-运营已取消';
COMMENT ON COLUMN src.src_mkt_loop_race.created_by IS '创建人（后台管理员ID）';
COMMENT ON COLUMN src.src_mkt_loop_race.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mkt_loop_race.update_time IS '更新时间';

CREATE TABLE src.src_mkt_loop_race_entry (
    race_id       BIGINT      NOT NULL REFERENCES src.src_mkt_loop_race (id) ON DELETE CASCADE,
    user_id       BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    entry_status  TEXT        NOT NULL DEFAULT 'signed' CHECK (entry_status IN ('signed', 'finished')),
    result_sec    INT,
    finish_time   TIMESTAMPTZ,
    activity_id   BIGINT      REFERENCES src.src_act_loop_activity (id) ON DELETE SET NULL,
    signup_time   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (race_id, user_id)
);
CREATE INDEX race_entry_user ON src.src_mkt_loop_race_entry (user_id);
CREATE INDEX race_entry_rank ON src.src_mkt_loop_race_entry (race_id, result_sec) WHERE entry_status = 'finished';
COMMENT ON TABLE src.src_mkt_loop_race_entry IS '赛事报名与成绩（开始前取消报名即删除）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.race_id IS '赛事ID';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.user_id IS '报名人（用户ID）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.entry_status IS '报名状态：signed-已报名 finished-已完赛（赛事结束仍为 signed 的，接口显示为 dnf-未完赛）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.result_sec IS '成绩（秒；线上赛按距离折算到赛事距离）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.finish_time IS '完赛时间';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.activity_id IS '完赛的运动记录ID（线上赛；线下赛为空）';
COMMENT ON COLUMN src.src_mkt_loop_race_entry.signup_time IS '报名时间';
