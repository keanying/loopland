COMMENT ON COLUMN src.src_ris_loop_alert.alert_type IS '告警类型：speed-速度异常 mock_location-模拟定位 teleport-轨迹瞬移 device_tamper-设备异常 missing_device_data-缺少设备信息 multi_account-多账号同设备';
ALTER TABLE src.src_act_loop_activity DROP COLUMN IF EXISTS coach_json;
ALTER TABLE src.src_soc_loop_post DROP COLUMN IF EXISTS ai_report_text, DROP COLUMN IF EXISTS hide_endpoints_m;
DROP INDEX IF EXISTS src.review_task_ai_retry;
DROP INDEX IF EXISTS src.review_task_created;
DROP INDEX IF EXISTS src.review_task_user;
ALTER TABLE src.src_cnt_loop_review_task
    DROP COLUMN IF EXISTS rule_score,
    DROP COLUMN IF EXISTS ai_score,
    DROP COLUMN IF EXISTS ai_labels_json,
    DROP COLUMN IF EXISTS ai_reason,
    DROP COLUMN IF EXISTS ai_confidence_rate,
    DROP COLUMN IF EXISTS ai_suggestion_type,
    DROP COLUMN IF EXISTS ai_model,
    DROP COLUMN IF EXISTS ai_flagged_images_json,
    DROP COLUMN IF EXISTS ai_status,
    DROP COLUMN IF EXISTS ai_retry_qty,
    DROP COLUMN IF EXISTS decision_type,
    DROP COLUMN IF EXISTS submit_type;
COMMENT ON COLUMN src.src_cnt_loop_review_task.risk_score IS '风险分 0-100：越高越可疑；按敏感词、联系方式、新用户等规则打分';
COMMENT ON COLUMN src.src_cnt_loop_review_task.review_status IS '审核状态：pending-待审核 approved-通过 rejected-拒绝';
DROP TABLE IF EXISTS src.src_act_loop_ai_report;
DROP TABLE IF EXISTS src.src_sys_loop_ai_call;
DROP TABLE IF EXISTS src.src_msg_loop_ai_message;
