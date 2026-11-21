-- 第三方服务配置（管理端「系统配置」页面维护）
CREATE TABLE src.src_sys_provider_config (
    provider_code     TEXT        PRIMARY KEY,
    is_enabled        BOOLEAN     NOT NULL DEFAULT false,
    is_saved          BOOLEAN     NOT NULL DEFAULT false,
    config_json       JSONB       NOT NULL DEFAULT '{}',
    secret_enc        BYTEA,
    check_status      TEXT        CHECK (check_status IN ('ok', 'fail')),
    check_message     TEXT,
    check_time        TIMESTAMPTZ,
    updated_by        BIGINT,
    update_time       TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE src.src_sys_provider_config IS '第三方服务配置：短信、验证码、一键登录、实名、微信、支付宝、Apple、AI、邮件、地图等';
COMMENT ON COLUMN src.src_sys_provider_config.provider_code IS '服务代码：aliyun-阿里云账号 sms-短信 captcha-验证码 oneclick-一键登录 realname-实名核验 wechat_login-微信登录 wechat_pay-微信支付 alipay-支付宝 apple-Apple ai-大模型 email-邮件 amap-高德 Web 服务';
COMMENT ON COLUMN src.src_sys_provider_config.is_enabled IS '是否启用：true-启用 false-停用（停用后 App 不显示对应入口）';
COMMENT ON COLUMN src.src_sys_provider_config.is_saved IS '是否已在管理端保存过：true-以本表配置为准 false-只记录了连通测试，仍使用 config.yaml/环境变量的配置';
COMMENT ON COLUMN src.src_sys_provider_config.config_json IS '非敏感配置项（JSON）';
COMMENT ON COLUMN src.src_sys_provider_config.secret_enc IS '敏感配置项（JSON，AES-256-GCM 加密，密钥为 LOOPLAND_DATA_KEY）';
COMMENT ON COLUMN src.src_sys_provider_config.check_status IS '最近一次连通测试结果：ok-通过 fail-失败 NULL-未测试';
COMMENT ON COLUMN src.src_sys_provider_config.check_message IS '最近一次连通测试说明';
COMMENT ON COLUMN src.src_sys_provider_config.check_time IS '最近一次连通测试时间';
COMMENT ON COLUMN src.src_sys_provider_config.updated_by IS '最后修改人（后台管理员ID，src_sys_admin.id）';
COMMENT ON COLUMN src.src_sys_provider_config.update_time IS '最后修改时间';
