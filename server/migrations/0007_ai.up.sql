-- V2 第三批「AI」（docs/api/v2-3-AI.md）：助手对话、模型调用记录、AI 战报、AI 审核字段、跟练上报

CREATE TABLE src.src_msg_loop_ai_message (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id              BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    role_type            TEXT        NOT NULL CHECK (role_type IN ('user', 'assistant')),
    content_text         TEXT        NOT NULL DEFAULT '',
    image_id             BIGINT      REFERENCES src.src_cnt_loop_media (id) ON DELETE SET NULL,
    image_url            TEXT,
    cards_json           JSONB       NOT NULL DEFAULT '[]',
    context_type         TEXT        CHECK (context_type IN ('territory', 'boss')),
    context_id           BIGINT,
    model_name           TEXT,
    prompt_token_qty     INT         NOT NULL DEFAULT 0,
    completion_token_qty INT         NOT NULL DEFAULT 0,
    is_quota_counted     BOOLEAN     NOT NULL DEFAULT false,
    is_output_blocked    BOOLEAN     NOT NULL DEFAULT false,
    delete_time          TIMESTAMPTZ,
    create_time          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ai_message_user ON src.src_msg_loop_ai_message (user_id, id DESC);
CREATE INDEX ai_message_quota ON src.src_msg_loop_ai_message (user_id, create_time) WHERE is_quota_counted;
CREATE INDEX ai_message_created ON src.src_msg_loop_ai_message (create_time);
COMMENT ON TABLE src.src_msg_loop_ai_message IS 'AI 助手圈圈的对话：用户提问与 AI 回答（保存 180 天用于投诉核查，用户清空为软删除）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.id IS '消息ID';
COMMENT ON COLUMN src.src_msg_loop_ai_message.user_id IS '对话所属用户ID';
COMMENT ON COLUMN src.src_msg_loop_ai_message.role_type IS '角色：user-用户提问 assistant-AI 回答';
COMMENT ON COLUMN src.src_msg_loop_ai_message.content_text IS '消息正文（AI 回答命中拦截词时为替换后的固定文案）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.image_id IS '用户随问题发送的图片ID（src_cnt_loop_media.id；没有为空）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.image_url IS '用户随问题发送的图片地址（没有为空）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.cards_json IS 'AI 回答里的卡片（JSON 数组，元素 type 为 route-路线 territory-领地 boss-怪兽；用户消息为空数组）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.context_type IS '「问 AI」带入的对象类型：territory-领地 boss-怪兽；没有为空';
COMMENT ON COLUMN src.src_msg_loop_ai_message.context_id IS '「问 AI」带入的对象ID（领地ID或怪兽ID）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.model_name IS '生成回答的模型（AI 回答才有）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.prompt_token_qty IS '这次回答消耗的输入 Token 数（含工具调用的多轮）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.completion_token_qty IS '这次回答消耗的输出 Token 数';
COMMENT ON COLUMN src.src_msg_loop_ai_message.is_quota_counted IS '是否扣了免费用户的每周次数（会员不扣；调用失败不保存）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.is_output_blocked IS '模型输出是否命中拦截词被替换';
COMMENT ON COLUMN src.src_msg_loop_ai_message.delete_time IS '用户清空对话的时间（软删除，后台保留到 180 天到期；未清空为空）';
COMMENT ON COLUMN src.src_msg_loop_ai_message.create_time IS '发送时间';

CREATE TABLE src.src_sys_loop_ai_call (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feature_type         TEXT        NOT NULL CHECK (feature_type IN ('chat', 'route', 'report', 'moderation', 'workout')),
    user_id              BIGINT      REFERENCES src.src_usr_loop_user (id) ON DELETE SET NULL,
    model_name           TEXT        NOT NULL,
    call_status          TEXT        NOT NULL CHECK (call_status IN ('ok', 'failed')),
    error_text           TEXT,
    prompt_token_qty     INT         NOT NULL DEFAULT 0,
    completion_token_qty INT         NOT NULL DEFAULT 0,
    latency_ms           INT         NOT NULL DEFAULT 0,
    is_mock              BOOLEAN     NOT NULL DEFAULT false,
    create_time          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ai_call_created ON src.src_sys_loop_ai_call (create_time);
CREATE INDEX ai_call_feature ON src.src_sys_loop_ai_call (feature_type, create_time);
COMMENT ON TABLE src.src_sys_loop_ai_call IS '大模型调用记录：每次调用的元数据（不含对话内容），用于用量、失败率、耗时和费用估算';
COMMENT ON COLUMN src.src_sys_loop_ai_call.id IS '调用记录ID';
COMMENT ON COLUMN src.src_sys_loop_ai_call.feature_type IS '功能：chat-助手对话 route-路线建议的解释 report-AI 战报 moderation-内容审核打分 workout-AI 跟练';
COMMENT ON COLUMN src.src_sys_loop_ai_call.user_id IS '触发调用的用户ID（审核为内容作者；没有为空）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.model_name IS '调用的模型名称（开发环境模拟 AI 为 mock）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.call_status IS '调用结果：ok-成功 failed-失败或超时';
COMMENT ON COLUMN src.src_sys_loop_ai_call.error_text IS '失败原因（成功为空，不含对话内容）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.prompt_token_qty IS '输入 Token 数（接口没返回时按字数估算）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.completion_token_qty IS '输出 Token 数（接口没返回时按字数估算）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.latency_ms IS '耗时（毫秒，流式调用为整段完成的耗时）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.is_mock IS '是否开发环境的模拟 AI（不产生费用）';
COMMENT ON COLUMN src.src_sys_loop_ai_call.create_time IS '调用时间';

CREATE TABLE src.src_act_loop_ai_report (
    activity_id          BIGINT      PRIMARY KEY REFERENCES src.src_act_loop_activity (id) ON DELETE CASCADE,
    user_id              BIGINT      NOT NULL REFERENCES src.src_usr_loop_user (id) ON DELETE CASCADE,
    report_text          TEXT        NOT NULL,
    model_name           TEXT        NOT NULL,
    regenerate_qty       INT         NOT NULL DEFAULT 0 CHECK (regenerate_qty >= 0),
    generate_time        TIMESTAMPTZ NOT NULL DEFAULT now(),
    create_time          TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ai_report_user ON src.src_act_loop_ai_report (user_id);
COMMENT ON TABLE src.src_act_loop_ai_report IS '运动的 AI 战报（小模型生成，每次运动一条，可重新生成 2 次）';
COMMENT ON COLUMN src.src_act_loop_ai_report.activity_id IS '运动记录ID（src_act_loop_activity.id）';
COMMENT ON COLUMN src.src_act_loop_ai_report.user_id IS '运动所属用户ID';
COMMENT ON COLUMN src.src_act_loop_ai_report.report_text IS '战报正文（≤ 玩法配置 ai.report_max_chars 字）';
COMMENT ON COLUMN src.src_act_loop_ai_report.model_name IS '生成战报的模型（公示名称）';
COMMENT ON COLUMN src.src_act_loop_ai_report.regenerate_qty IS '已重新生成的次数（最多 2 次）';
COMMENT ON COLUMN src.src_act_loop_ai_report.generate_time IS '最近一次生成的时间';
COMMENT ON COLUMN src.src_act_loop_ai_report.create_time IS '第一次生成的时间';
COMMENT ON COLUMN src.src_act_loop_ai_report.update_time IS '最后修改时间';

-- 内容审核：AI 判定（M-16 ~ M-19）
ALTER TABLE src.src_cnt_loop_review_task
    ADD COLUMN rule_score            INT CHECK (rule_score BETWEEN 0 AND 100),
    ADD COLUMN ai_score              INT CHECK (ai_score BETWEEN 0 AND 100),
    ADD COLUMN ai_labels_json        JSONB NOT NULL DEFAULT '[]',
    ADD COLUMN ai_reason             TEXT,
    ADD COLUMN ai_confidence_rate    DOUBLE PRECISION CHECK (ai_confidence_rate BETWEEN 0 AND 1),
    ADD COLUMN ai_suggestion_type    TEXT CHECK (ai_suggestion_type IN ('reject', 'review', 'approve', 'mask', 'hide_endpoints')),
    ADD COLUMN ai_model              TEXT,
    ADD COLUMN ai_flagged_images_json JSONB NOT NULL DEFAULT '[]',
    ADD COLUMN ai_status             TEXT NOT NULL DEFAULT 'none' CHECK (ai_status IN ('none', 'ok', 'retry', 'failed')),
    ADD COLUMN ai_retry_qty          INT NOT NULL DEFAULT 0,
    ADD COLUMN decision_type         TEXT CHECK (decision_type IN ('manual', 'auto_approve', 'auto_reject')),
    ADD COLUMN submit_type           TEXT NOT NULL DEFAULT 'submit' CHECK (submit_type IN ('submit', 'report'));
CREATE INDEX review_task_ai_retry ON src.src_cnt_loop_review_task (create_time) WHERE ai_status = 'retry';
CREATE INDEX review_task_created ON src.src_cnt_loop_review_task (create_time);
CREATE INDEX review_task_user ON src.src_cnt_loop_review_task (user_id, review_status);
COMMENT ON COLUMN src.src_cnt_loop_review_task.risk_score IS '最终风险分 0-100：规则分与 AI 分取高，越高越可疑';
COMMENT ON COLUMN src.src_cnt_loop_review_task.review_status IS '审核状态：pending-待审核 approved-通过（人工或低于自动放行线） rejected-拒绝（人工或达到自动拦截线）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.rule_score IS '规则分 0-100：敏感词、联系方式、新用户发图（第二批之前的任务为空）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_score IS 'AI 风险分 0-100（没有 AI 判定为空）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_labels_json IS 'AI 风险标签（JSON 数组）：ad-广告引流 contact-联系方式 porn-色情 politics-涉政 abuse-辱骂 fraud-诈骗 illegal-违法 privacy-隐私泄露 minor-未成年人 other-其他';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_reason IS 'AI 判定理由';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_confidence_rate IS 'AI 判定置信度 0-1';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_suggestion_type IS 'AI 处理建议：reject-拒绝 review-人工复核 approve-通过 mask-打码后通过 hide_endpoints-隐藏起终点后通过';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_model IS '做出判定的模型（公示名称）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_flagged_images_json IS 'AI 识别为违规的图片地址（JSON 数组；打码后通过时移除）';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_status IS 'AI 打分状态：none-未打分（未启用或无可用模型） ok-已打分 retry-同步打分超时或失败，等后台补打分 failed-补打分多次失败，放弃';
COMMENT ON COLUMN src.src_cnt_loop_review_task.ai_retry_qty IS '后台补打分已尝试的次数';
COMMENT ON COLUMN src.src_cnt_loop_review_task.decision_type IS '处理方式：manual-人工审核 auto_approve-低于自动放行线直接通过 auto_reject-达到自动拦截线直接拒绝；待审核为空';
COMMENT ON COLUMN src.src_cnt_loop_review_task.submit_type IS '来源：submit-发布或修改时送审 report-被举报转入';

-- 动态：附 AI 战报、单条动态的起终点隐藏半径
ALTER TABLE src.src_soc_loop_post
    ADD COLUMN ai_report_text   TEXT,
    ADD COLUMN hide_endpoints_m DOUBLE PRECISION CHECK (hide_endpoints_m >= 0);
COMMENT ON COLUMN src.src_soc_loop_post.ai_report_text IS '附带的 AI 战报正文（发布时从 src_act_loop_ai_report 复制，不计入 500 字；没带为空）';
COMMENT ON COLUMN src.src_soc_loop_post.hide_endpoints_m IS '这条动态的轨迹起终点隐藏半径（米；审核「隐藏起终点后通过」设为 500；为空时按作者设置）';

-- 运动：AI 跟练上报
ALTER TABLE src.src_act_loop_activity ADD COLUMN coach_json JSONB;
COMMENT ON COLUMN src.src_act_loop_activity.coach_json IS 'AI 跟练信息（JSON：workout_key 动作套路、camera 是否摄像头计次、reps_detected 识别次数、reps_manual 手动补记次数、sets_done 完成组数；没用跟练为空）';
COMMENT ON COLUMN src.src_ris_loop_alert.alert_type IS '告警类型：speed-速度异常 mock_location-模拟定位 teleport-轨迹瞬移 device_tamper-设备异常 missing_device_data-缺少设备信息 multi_account-多账号同设备 coach_mismatch-跟练上报次数比摄像头识别多 20% 以上';
