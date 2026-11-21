-- 圈圈 Loopland 业务库基线（命名规范见 docs/数据库与命名规范.md）
-- 坐标统一为 GCJ-02（高德），以 SRID 4326 存储；面积按 geography 计算。
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS src;
COMMENT ON SCHEMA src IS '业务源层（SRC）：线上业务库';

CREATE OR REPLACE FUNCTION lp_clean(g geometry) RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
  SELECT ST_SetSRID(ST_Multi(ST_CollectionExtract(ST_MakeValid(g), 3)), 4326)
$$;

CREATE OR REPLACE FUNCTION lp_area(g geometry) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(ST_Area(g::geography), 0)
$$;

CREATE TABLE src.src_usr_user (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone_enc           BYTEA,
    phone_hash          BYTEA UNIQUE,
    phone_last4         TEXT,
    nickname            TEXT        NOT NULL,
    avatar_url          TEXT,
    source              TEXT        NOT NULL,
    energy              INT         NOT NULL DEFAULT 0 CHECK (energy >= 0),
    energy_earned_total BIGINT      NOT NULL DEFAULT 0,
    is_realname_verified   BOOLEAN     NOT NULL DEFAULT false,
    is_adult            BOOLEAN,
    birth_year          INT,
    status              TEXT        NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'banned', 'deleting', 'deleted')),
    mute_end_time         TIMESTAMPTZ,
    ban_end_time        TIMESTAMPTZ,
    delete_time        TIMESTAMPTZ,
    consents_json            JSONB       NOT NULL DEFAULT '{}',
    settings_json            JSONB       NOT NULL DEFAULT '{"track_visibility":"public","hide_endpoints":true,"show_avatar_on_map":true,"personalized":true}',
    escort_companion_key    TEXT,
    last_login_time       TIMESTAMPTZ,
    create_time          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX users_phone_last4 ON src.src_usr_user (phone_last4);
CREATE INDEX users_created ON src.src_usr_user (create_time);

CREATE TABLE src.src_usr_identity (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    provider        TEXT        NOT NULL,
    provider_uid    TEXT        NOT NULL,
    union_id        TEXT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, provider_uid)
);
CREATE INDEX user_identities_user ON src.src_usr_identity (user_id);
CREATE UNIQUE INDEX user_identities_union ON src.src_usr_identity (provider, union_id) WHERE union_id IS NOT NULL;

CREATE TABLE src.src_usr_refresh_token (
    token_hash      BYTEA       PRIMARY KEY,
    family          UUID        NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    device_id       TEXT,
    expire_time      TIMESTAMPTZ NOT NULL,
    use_time         TIMESTAMPTZ,
    revoke_time      TIMESTAMPTZ,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_family ON src.src_usr_refresh_token (family);
CREATE INDEX refresh_tokens_user ON src.src_usr_refresh_token (user_id);

CREATE TABLE src.src_usr_device (
    device_id       TEXT        NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    last_seen_time    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, user_id)
);

CREATE TABLE src.src_soc_crew (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL UNIQUE,
    avatar_url      TEXT,
    district        TEXT        NOT NULL,
    join_mode       TEXT        NOT NULL DEFAULT 'open' CHECK (join_mode IN ('open', 'apply', 'invite')),
    leader_id       BIGINT      NOT NULL REFERENCES src.src_usr_user (id),
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_soc_crew_member (
    crew_id         BIGINT      NOT NULL REFERENCES src.src_soc_crew (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    join_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (crew_id, user_id),
    UNIQUE (user_id)
);

CREATE TABLE src.src_soc_crew_apply (
    crew_id         BIGINT      NOT NULL REFERENCES src.src_soc_crew (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (crew_id, user_id)
);

CREATE TABLE src.src_ply_energy_ledger (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    ledger_date     DATE        NOT NULL,
    delta           INT         NOT NULL,
    reason          TEXT        NOT NULL,
    ref_id          BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX energy_ledger_user_day ON src.src_ply_energy_ledger (user_id, ledger_date);

CREATE TABLE src.src_act_activity (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    client_id       UUID        NOT NULL,
    sport           TEXT        NOT NULL,
    start_time      TIMESTAMPTZ NOT NULL,
    end_time        TIMESTAMPTZ NOT NULL,
    distance_m      DOUBLE PRECISION NOT NULL DEFAULT 0,
    duration_sec      INT         NOT NULL DEFAULT 0,
    amount          DOUBLE PRECISION NOT NULL DEFAULT 0,
    energy_raw      INT         NOT NULL DEFAULT 0,
    energy_granted  INT         NOT NULL DEFAULT 0,
    claimed_area_m2 DOUBLE PRECISION NOT NULL DEFAULT 0,
    track_geom           geometry(LineString, 4326),
    goal_json            JSONB,
    device_json          JSONB,
    wearable_json        JSONB,
    status          TEXT        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'settled', 'voided', 'review')),
    result_json          JSONB,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, client_id)
);
CREATE INDEX activities_user_time ON src.src_act_activity (user_id, start_time DESC);
CREATE INDEX activities_created ON src.src_act_activity (create_time);

CREATE TABLE src.src_act_track_point (
    activity_id     BIGINT      NOT NULL,
    seq             INT         NOT NULL,
    record_time     TIMESTAMPTZ NOT NULL,
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    accuracy_m      REAL,
    speed_mps       REAL,
    heart_rate      SMALLINT,
    cadence         SMALLINT,
    source          TEXT,
    PRIMARY KEY (record_time, activity_id, seq)
) PARTITION BY RANGE (record_time);
CREATE TABLE src.src_act_track_point_default PARTITION OF src.src_act_track_point DEFAULT;
CREATE INDEX track_points_activity ON src.src_act_track_point (activity_id, seq);

CREATE TABLE src.src_act_sport_total (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    sport           TEXT        NOT NULL,
    amount          DOUBLE PRECISION NOT NULL DEFAULT 0,
    distance_m      DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, sport)
);

CREATE TABLE src.src_ter_territory (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT,
    owner_user_id   BIGINT      REFERENCES src.src_usr_user (id),
    owner_crew_id   BIGINT      REFERENCES src.src_soc_crew (id) ON DELETE SET NULL,
    area_geom            geometry(MultiPolygon, 4326) NOT NULL,
    area_m2         DOUBLE PRECISION NOT NULL,
    guard           INT         NOT NULL DEFAULT 0 CHECK (guard >= 0),
    is_frozen          BOOLEAN     NOT NULL DEFAULT false,
    source_activity BIGINT      REFERENCES src.src_act_activity (id) ON DELETE SET NULL,
    capture_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territories_geom ON src.src_ter_territory USING GIST (area_geom);
CREATE INDEX territories_owner ON src.src_ter_territory (owner_user_id);
CREATE INDEX territories_crew ON src.src_ter_territory (owner_crew_id);

CREATE TABLE src.src_ter_event (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    territory_id    BIGINT      NOT NULL REFERENCES src.src_ter_territory (id) ON DELETE CASCADE,
    activity_id     BIGINT      REFERENCES src.src_act_activity (id) ON DELETE SET NULL,
    event_type            TEXT        NOT NULL CHECK (event_type IN (
                        'claim', 'capture', 'capture_whole', 'cut', 'weaken', 'build', 'reinforce',
                        'freeze', 'unfreeze', 'reset', 'rollback', 'admin_guard', 'owner_deleted')),
    actor_user_id   BIGINT,
    prev_owner_id   BIGINT,
    new_owner_id    BIGINT,
    prev_guard      INT,
    new_guard       INT,
    prev_area_geom       geometry(MultiPolygon, 4326),
    prev_state_json      JSONB,
    admin_id        BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territory_events_territory ON src.src_ter_event (territory_id, id DESC);
CREATE INDEX territory_events_activity ON src.src_ter_event (activity_id);
CREATE INDEX territory_events_created ON src.src_ter_event (create_time);

CREATE TABLE src.src_ter_building (
    territory_id    BIGINT      NOT NULL REFERENCES src.src_ter_territory (id) ON DELETE CASCADE,
    slot            SMALLINT    NOT NULL CHECK (slot BETWEEN 0 AND 15),
    building        TEXT        NOT NULL,
    built_by        BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    build_time        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (territory_id, slot)
);

CREATE TABLE src.src_ter_station (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    role            TEXT        NOT NULL,
    territory_id    BIGINT      NOT NULL REFERENCES src.src_ter_territory (id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role)
);
CREATE INDEX territory_stationed_territory ON src.src_ter_station (territory_id);

CREATE TABLE src.src_ply_codex_item (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    item_type            TEXT        NOT NULL CHECK (item_type IN ('role', 'blueprint', 'egg', 'companion', 'monster', 'medal')),
    item            TEXT        NOT NULL,
    progress        DOUBLE PRECISION NOT NULL DEFAULT 0,
    obtain_time     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, item_type, item)
);

CREATE TABLE src.src_ris_alert (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_id     BIGINT      REFERENCES src.src_act_activity (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    alert_type            TEXT        NOT NULL,
    confidence      REAL        NOT NULL,
    detail          TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
    resolution      TEXT,
    note            TEXT,
    resolved_by     BIGINT,
    resolve_time     TIMESTAMPTZ,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX risk_alerts_status ON src.src_ris_alert (status, confidence DESC);
CREATE INDEX risk_alerts_user ON src.src_ris_alert (user_id);

CREATE TABLE src.src_ord_plan (
    code            TEXT        PRIMARY KEY,
    name            TEXT        NOT NULL,
    period_type     TEXT        NOT NULL CHECK (period_type IN ('month', 'quarter', 'year')),
    is_auto_renew      BOOLEAN     NOT NULL DEFAULT false,
    price_amt       INT         NOT NULL CHECK (price_amt > 0),
    first_price_amt INT         CHECK (first_price_amt > 0),
    renew_price_amt INT         NOT NULL CHECK (renew_price_amt > 0),
    seats           INT         NOT NULL DEFAULT 1,
    is_recommended     BOOLEAN     NOT NULL DEFAULT false,
    is_on_sale         BOOLEAN     NOT NULL DEFAULT true,
    sort            INT         NOT NULL DEFAULT 0,
    apple_product_id TEXT,
    entitlements    TEXT[]      NOT NULL DEFAULT '{}',
    CHECK (NOT ('guard_bonus' = ANY (entitlements) OR 'extra_energy' = ANY (entitlements)))
);

CREATE TABLE src.src_ord_order (
    order_no        TEXT        PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    plan_code       TEXT        NOT NULL REFERENCES src.src_ord_plan (code),
    plan_name       TEXT        NOT NULL,
    order_amt      INT         NOT NULL,
    channel         TEXT        NOT NULL,
    order_type      TEXT        NOT NULL DEFAULT 'purchase' CHECK (order_type IN ('purchase', 'renewal', 'gift')),
    status          TEXT        NOT NULL DEFAULT 'created'
                    CHECK (status IN ('created', 'paid', 'refund_requested', 'refunded', 'closed', 'renew_failed')),
    trade_no        TEXT,
    app_account_token UUID,
    pay_time         TIMESTAMPTZ,
    refund_time     TIMESTAMPTZ,
    refund_reason   TEXT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX orders_user ON src.src_ord_order (user_id, create_time DESC);
CREATE INDEX orders_status ON src.src_ord_order (status, create_time DESC);
CREATE UNIQUE INDEX orders_trade ON src.src_ord_order (channel, trade_no) WHERE trade_no IS NOT NULL;
CREATE UNIQUE INDEX orders_apple_token ON src.src_ord_order (app_account_token) WHERE app_account_token IS NOT NULL;

CREATE TABLE src.src_ord_membership (
    user_id         BIGINT      PRIMARY KEY REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    plan_code       TEXT        NOT NULL REFERENCES src.src_ord_plan (code),
    channel         TEXT        NOT NULL,
    expire_time      TIMESTAMPTZ NOT NULL,
    is_auto_renew      BOOLEAN     NOT NULL DEFAULT false,
    next_charge_time  TIMESTAMPTZ,
    reminded_charge_time    TIMESTAMPTZ,
    grace_end_time     TIMESTAMPTZ,
    apple_original_transaction_id TEXT,
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_msg_notification (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    category        TEXT        NOT NULL CHECK (category IN ('interaction', 'territory', 'monster', 'system')),
    title           TEXT        NOT NULL,
    body            TEXT        NOT NULL,
    data_json            JSONB       NOT NULL DEFAULT '{}',
    read_time         TIMESTAMPTZ,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX notifications_user ON src.src_msg_notification (user_id, id DESC);

CREATE TABLE src.src_sys_gameplay_config (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version         TEXT        NOT NULL UNIQUE,
    config_json     JSONB       NOT NULL,
    rollout_pct     SMALLINT    NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 1 AND 100),
    note            TEXT,
    published_by    BIGINT,
    publish_time    TIMESTAMPTZ NOT NULL DEFAULT now(),
    rollback_time  TIMESTAMPTZ
);

CREATE TABLE src.src_sys_setting (
    setting_key     TEXT        PRIMARY KEY,
    setting_value   JSONB       NOT NULL,
    update_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_sys_admin (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username        TEXT        NOT NULL UNIQUE,
    password_hash   TEXT        NOT NULL,
    role            TEXT        NOT NULL CHECK (role IN ('admin', 'ops', 'reviewer', 'merchant')),
    is_disabled        BOOLEAN     NOT NULL DEFAULT false,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_sys_audit_log (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id        BIGINT      NOT NULL REFERENCES src.src_sys_admin (id),
    action          TEXT        NOT NULL,
    target          TEXT        NOT NULL,
    detail_json     JSONB       NOT NULL DEFAULT '{}',
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_created ON src.src_sys_audit_log (id DESC);

INSERT INTO src.src_ord_plan (code, name, period_type, is_auto_renew, price_amt, first_price_amt, renew_price_amt, seats, is_recommended, sort, apple_product_id, entitlements) VALUES
 ('auto_month', '连续包月', 'month',   true,  1800, 1500, 1800, 1, true,  1, 'com.loopland.member.auto_month', '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('month',      '月卡',     'month',   false, 1800, NULL, 1800, 1, false, 2, 'com.loopland.member.month',      '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('quarter',    '季卡',     'quarter', false, 4500, NULL, 4500, 1, false, 3, 'com.loopland.member.quarter',    '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('year',       '年卡',     'year',    false, 16800, NULL, 16800, 1, false, 4, 'com.loopland.member.year',     '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('crew_year',  '跑团版',   'year',    false, 29800, NULL, 29800, 5, false, 5, 'com.loopland.member.crew_year', '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export,crew_tools}');

INSERT INTO src.src_sys_setting (setting_key, setting_value) VALUES
 ('risk_rules', '{"run_max_kmh":20,"ride_max_kmh":45,"hike_max_kmh":12,"walk_max_kmh":10,"teleport_m":500,"gap_s":30,"require_wearable_for_events":true}');

CREATE TABLE src.src_ply_boss (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    boss_type            TEXT        NOT NULL,
    name            TEXT        NOT NULL,
    level           INT         NOT NULL DEFAULT 1,
    location_name   TEXT        NOT NULL DEFAULT '',
    center_geom          geometry(Point, 4326) NOT NULL,
    radius_m        DOUBLE PRECISION NOT NULL,
    hp_max          INT         NOT NULL CHECK (hp_max > 0),
    hp              INT         NOT NULL CHECK (hp >= 0),
    status          TEXT        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'defeated', 'expired')),
    drops_json           JSONB       NOT NULL,
    spawned_by      BIGINT,
    spawn_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expire_time      TIMESTAMPTZ NOT NULL,
    end_time        TIMESTAMPTZ
);
CREATE INDEX idx_ply_boss_active ON src.src_ply_boss USING GIST (center_geom) WHERE status = 'active';
CREATE INDEX bosses_status ON src.src_ply_boss (status, spawn_time DESC);

CREATE TABLE src.src_ply_boss_hit (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    boss_id         BIGINT      NOT NULL REFERENCES src.src_ply_boss (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    crew_id         BIGINT,
    source          TEXT        NOT NULL CHECK (source IN ('strike', 'activity')),
    activity_id     BIGINT      REFERENCES src.src_act_activity (id) ON DELETE SET NULL,
    damage          INT         NOT NULL,
    energy_spent    INT         NOT NULL DEFAULT 0,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX boss_hits_boss ON src.src_ply_boss_hit (boss_id, user_id);
CREATE INDEX boss_hits_user ON src.src_ply_boss_hit (user_id, create_time DESC);

CREATE TABLE src.src_ply_boss_engage (
    boss_id         BIGINT      NOT NULL REFERENCES src.src_ply_boss (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    engage_end_time TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (boss_id, user_id)
);

CREATE TABLE src.src_ply_boss_reward (
    boss_id         BIGINT      NOT NULL REFERENCES src.src_ply_boss (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    rank            INT         NOT NULL,
    damage          INT         NOT NULL,
    items_json           JSONB       NOT NULL,
    energy          INT         NOT NULL DEFAULT 0,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (boss_id, user_id)
);

CREATE TABLE src.src_ply_user_monster (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    boss_type            TEXT        NOT NULL,
    strikes         INT         NOT NULL DEFAULT 0,
    defeats         INT         NOT NULL DEFAULT 0,
    best_rank       INT,
    PRIMARY KEY (user_id, boss_type)
);

CREATE TABLE src.src_ply_chest (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    center_geom          geometry(Point, 4326) NOT NULL,
    radius_m        DOUBLE PRECISION NOT NULL,
    energy_min      INT         NOT NULL,
    energy_max      INT         NOT NULL,
    source          TEXT        NOT NULL DEFAULT 'system',
    placed_by       BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expire_time      TIMESTAMPTZ NOT NULL,
    remove_time      TIMESTAMPTZ
);
CREATE INDEX chests_center ON src.src_ply_chest USING GIST (center_geom);
CREATE INDEX chests_expires ON src.src_ply_chest (expire_time);

CREATE TABLE src.src_ply_chest_open (
    chest_id        BIGINT      NOT NULL REFERENCES src.src_ply_chest (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    energy          INT         NOT NULL,
    is_bonus           BOOLEAN     NOT NULL DEFAULT false,
    activity_id     BIGINT,
    open_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chest_id, user_id)
);

CREATE TABLE src.src_ter_defense (
    territory_id    BIGINT      PRIMARY KEY REFERENCES src.src_ter_territory (id) ON DELETE CASCADE,
    attacker_id     BIGINT,
    open_time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deadline_time        TIMESTAMPTZ NOT NULL
);

CREATE TABLE src.src_usr_stat (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    stat_key        TEXT        NOT NULL,
    stat_value      DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, stat_key)
);

CREATE TABLE src.src_ply_season (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL,
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ NOT NULL CHECK (end_time > start_time),
    settle_time      TIMESTAMPTZ,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    EXCLUDE USING gist (tstzrange(start_time, end_time) WITH &&)
);

CREATE TABLE src.src_ply_season_result (
    season_id       BIGINT      NOT NULL REFERENCES src.src_ply_season (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    area_m2         DOUBLE PRECISION NOT NULL,
    rank            INT         NOT NULL,
    tier            TEXT        NOT NULL,
    PRIMARY KEY (season_id, user_id)
);

CREATE TABLE src.src_ply_task_done (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    task_key        TEXT        NOT NULL,
    week_start_date DATE        NOT NULL,
    reward_energy   INT         NOT NULL,
    complete_time    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, task_key, week_start_date)
);

CREATE TABLE src.src_ply_league_result (
    week_start_date      DATE        NOT NULL,
    district        TEXT        NOT NULL,
    crew_id         BIGINT      NOT NULL REFERENCES src.src_soc_crew (id) ON DELETE CASCADE,
    rank            INT         NOT NULL,
    score_m2        DOUBLE PRECISION NOT NULL,
    active_members  INT         NOT NULL,
    PRIMARY KEY (week_start_date, district, crew_id)
);

CREATE TABLE src.src_mkt_campaign (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title           TEXT        NOT NULL,
    campaign_type            TEXT        NOT NULL CHECK (campaign_type IN ('pace', 'night_run', 'distance')),
    description     TEXT        NOT NULL DEFAULT '',
    rules_json           JSONB       NOT NULL,
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ NOT NULL CHECK (end_time > start_time),
    reward_energy   INT         NOT NULL DEFAULT 0,
    reward_medal_name TEXT,
    created_by      BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_mkt_campaign_done (
    campaign_id     BIGINT      NOT NULL REFERENCES src.src_mkt_campaign (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    activity_id     BIGINT,
    complete_time    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (campaign_id, user_id)
);

CREATE TABLE src.src_ply_route (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL,
    description     TEXT        NOT NULL DEFAULT '',
    checkpoints_json     JSONB       NOT NULL,
    bbox            geometry(Polygon, 4326),
    reward_energy   INT         NOT NULL DEFAULT 0,
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ NOT NULL CHECK (end_time > start_time),
    created_by      BIGINT,
    create_time      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE src.src_ply_route_progress (
    route_id        BIGINT      NOT NULL REFERENCES src.src_ply_route (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    next_index      INT         NOT NULL DEFAULT 0,
    complete_time    TIMESTAMPTZ,
    PRIMARY KEY (route_id, user_id)
);

CREATE TABLE src.src_ply_companion_growth (
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    companion       TEXT        NOT NULL,
    exp             INT         NOT NULL DEFAULT 0,
    meters          DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, companion)
);

CREATE TABLE src.src_soc_relay (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    crew_id         BIGINT      NOT NULL REFERENCES src.src_soc_crew (id) ON DELETE CASCADE,
    legs            INT         NOT NULL CHECK (legs BETWEEN 2 AND 20),
    leg_km          DOUBLE PRECISION NOT NULL CHECK (leg_km > 0),
    status          TEXT        NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'expired')),
    started_by      BIGINT      NOT NULL,
    start_time      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expire_time      TIMESTAMPTZ NOT NULL,
    complete_time    TIMESTAMPTZ
);
CREATE UNIQUE INDEX relays_one_running ON src.src_soc_relay (crew_id) WHERE status = 'running';

CREATE TABLE src.src_soc_relay_run (
    relay_id        BIGINT      NOT NULL REFERENCES src.src_soc_relay (id) ON DELETE CASCADE,
    leg             INT         NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES src.src_usr_user (id) ON DELETE CASCADE,
    activity_id     BIGINT,
    distance_m      DOUBLE PRECISION NOT NULL,
    run_time        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (relay_id, leg),
    UNIQUE (relay_id, user_id)
);


-- ---------------------------------------------------------------- comments

COMMENT ON TABLE src.src_usr_user IS '用户账号';
COMMENT ON TABLE src.src_usr_identity IS '第三方登录身份（微信、Apple）';
COMMENT ON TABLE src.src_usr_refresh_token IS '刷新令牌（轮换，复用即整组作废）';
COMMENT ON TABLE src.src_usr_device IS '用户设备（多账号同设备风控）';
COMMENT ON TABLE src.src_usr_stat IS '用户成就计数（奖牌进度）';
COMMENT ON TABLE src.src_act_activity IS '运动记录';
COMMENT ON TABLE src.src_act_track_point IS '轨迹点（按 record_time 范围分区）';
COMMENT ON TABLE src.src_act_sport_total IS '用户各运动累计（角色招募）';
COMMENT ON TABLE src.src_ter_territory IS '领地';
COMMENT ON TABLE src.src_ter_event IS '领地变更记录（审计、作弊回滚）';
COMMENT ON TABLE src.src_ter_building IS '领地建筑';
COMMENT ON TABLE src.src_ter_station IS '角色驻扎';
COMMENT ON TABLE src.src_ter_defense IS '守地挑战窗口';
COMMENT ON TABLE src.src_ply_energy_ledger IS '能量流水';
COMMENT ON TABLE src.src_ply_codex_item IS '图鉴收集';
COMMENT ON TABLE src.src_ply_companion_growth IS '伙伴养成';
COMMENT ON TABLE src.src_ply_boss IS '城市怪兽';
COMMENT ON TABLE src.src_ply_boss_hit IS '怪兽伤害记录';
COMMENT ON TABLE src.src_ply_boss_engage IS '出战登记（居家运动对怪兽造成伤害）';
COMMENT ON TABLE src.src_ply_boss_reward IS '怪兽结算奖励';
COMMENT ON TABLE src.src_ply_user_monster IS '怪兽图鉴（参与记录）';
COMMENT ON TABLE src.src_ply_chest IS '能量宝箱';
COMMENT ON TABLE src.src_ply_chest_open IS '宝箱开启记录';
COMMENT ON TABLE src.src_ply_season IS '赛季';
COMMENT ON TABLE src.src_ply_season_result IS '赛季结算结果';
COMMENT ON TABLE src.src_ply_task_done IS '赛季任务完成记录（每周）';
COMMENT ON TABLE src.src_ply_league_result IS '城区联赛周结算';
COMMENT ON TABLE src.src_ply_route IS '城市定向路线';
COMMENT ON TABLE src.src_ply_route_progress IS '城市定向进度';
COMMENT ON TABLE src.src_mkt_campaign IS '限时活动';
COMMENT ON TABLE src.src_mkt_campaign_done IS '限时活动完成记录';
COMMENT ON TABLE src.src_soc_crew IS '跑团';
COMMENT ON TABLE src.src_soc_crew_member IS '跑团成员';
COMMENT ON TABLE src.src_soc_crew_apply IS '入团申请';
COMMENT ON TABLE src.src_soc_relay IS '跑团接力';
COMMENT ON TABLE src.src_soc_relay_run IS '接力每一棒';
COMMENT ON TABLE src.src_ris_alert IS '风控告警';
COMMENT ON TABLE src.src_ord_plan IS '会员套餐';
COMMENT ON TABLE src.src_ord_order IS '会员订单';
COMMENT ON TABLE src.src_ord_membership IS '会员资格';
COMMENT ON TABLE src.src_msg_notification IS '站内消息';
COMMENT ON TABLE src.src_sys_gameplay_config IS '玩法配置版本';
COMMENT ON TABLE src.src_sys_setting IS '系统设置（风控规则、任务记录等）';
COMMENT ON TABLE src.src_sys_admin IS '后台管理员';
COMMENT ON TABLE src.src_sys_audit_log IS '后台操作审计日志';
COMMENT ON COLUMN src.src_act_activity.id IS '主键';
COMMENT ON COLUMN src.src_act_activity.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_act_activity.client_id IS '客户端生成的上传ID（UUID，幂等）';
COMMENT ON COLUMN src.src_act_activity.sport IS '运动类型：run-跑步 ride-骑行 hike-徒步 walk-健走 strength-力量 yoga-瑜伽 rope-跳绳 hiit-HIIT';
COMMENT ON COLUMN src.src_act_activity.start_time IS '开始时间';
COMMENT ON COLUMN src.src_act_activity.end_time IS '结束时间';
COMMENT ON COLUMN src.src_act_activity.distance_m IS '距离（米，GPS 运动由服务端计算）';
COMMENT ON COLUMN src.src_act_activity.duration_sec IS '时长（秒）';
COMMENT ON COLUMN src.src_act_activity.amount IS '换算能量用的数量（单位见能量规则：公里、分钟或次数）';
COMMENT ON COLUMN src.src_act_activity.energy_raw IS '本次运动换算出的能量（未计日上限，也是抢地攻击力）';
COMMENT ON COLUMN src.src_act_activity.energy_granted IS '实际发放的能量（计入每日 600 上限后）';
COMMENT ON COLUMN src.src_act_activity.claimed_area_m2 IS '本次圈到和抢到的面积（平方米）';
COMMENT ON COLUMN src.src_act_activity.track_geom IS '轨迹线（GCJ-02）';
COMMENT ON COLUMN src.src_act_activity.goal_json IS '运动前目标：type free-自由圈地 distance-定距离 time-定时间 target-抢指定领地';
COMMENT ON COLUMN src.src_act_activity.device_json IS '上传设备信息（是否 root、模拟器、多开）';
COMMENT ON COLUMN src.src_act_activity.wearable_json IS '穿戴设备：brand apple / huawei / garmin / coros';
COMMENT ON COLUMN src.src_act_activity.status IS '结算状态：pending-待结算 settled-已结算 review-人工复核中 voided-已作废';
COMMENT ON COLUMN src.src_act_activity.result_json IS '结算结果（返回给客户端的 settlement）';
COMMENT ON COLUMN src.src_act_activity.create_time IS '创建时间';
COMMENT ON COLUMN src.src_act_sport_total.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_act_sport_total.sport IS '运动类型：run-跑步 ride-骑行 hike-徒步 walk-健走 strength-力量 yoga-瑜伽 rope-跳绳 hiit-HIIT';
COMMENT ON COLUMN src.src_act_sport_total.amount IS '累计数量（单位见能量规则）';
COMMENT ON COLUMN src.src_act_sport_total.distance_m IS '累计距离（米）';
COMMENT ON COLUMN src.src_act_track_point.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_act_track_point.seq IS '点序号（从 0 开始）';
COMMENT ON COLUMN src.src_act_track_point.record_time IS '定位时间';
COMMENT ON COLUMN src.src_act_track_point.lat IS '纬度（GCJ-02）';
COMMENT ON COLUMN src.src_act_track_point.lng IS '经度（GCJ-02）';
COMMENT ON COLUMN src.src_act_track_point.accuracy_m IS '定位精度（米）';
COMMENT ON COLUMN src.src_act_track_point.speed_mps IS '瞬时速度（米/秒）';
COMMENT ON COLUMN src.src_act_track_point.heart_rate IS '心率（次/分）';
COMMENT ON COLUMN src.src_act_track_point.cadence IS '步频（步/分）';
COMMENT ON COLUMN src.src_act_track_point.source IS '定位来源：gps-卫星 network-网络 mock-模拟定位（风控）';
COMMENT ON COLUMN src.src_mkt_campaign.id IS '主键';
COMMENT ON COLUMN src.src_mkt_campaign.title IS '活动标题';
COMMENT ON COLUMN src.src_mkt_campaign.campaign_type IS '活动类型：pace-配速挑战 night_run-夜跑专场 distance-距离挑战';
COMMENT ON COLUMN src.src_mkt_campaign.description IS '说明';
COMMENT ON COLUMN src.src_mkt_campaign.rules_json IS '规则：min_distance_km 最低距离，max_pace_s_per_km 最慢配速（秒/公里），start_hour_from / start_hour_to 开跑时段';
COMMENT ON COLUMN src.src_mkt_campaign.start_time IS '开始时间';
COMMENT ON COLUMN src.src_mkt_campaign.end_time IS '结束时间';
COMMENT ON COLUMN src.src_mkt_campaign.reward_energy IS '奖励能量';
COMMENT ON COLUMN src.src_mkt_campaign.reward_medal_name IS '奖励奖牌名称（可空）';
COMMENT ON COLUMN src.src_mkt_campaign.created_by IS '创建人（后台管理员ID，src_sys_admin.id）';
COMMENT ON COLUMN src.src_mkt_campaign.create_time IS '创建时间';
COMMENT ON COLUMN src.src_mkt_campaign_done.campaign_id IS '活动ID（src_mkt_campaign.id）';
COMMENT ON COLUMN src.src_mkt_campaign_done.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_mkt_campaign_done.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_mkt_campaign_done.complete_time IS '完成时间';
COMMENT ON COLUMN src.src_msg_notification.id IS '主键';
COMMENT ON COLUMN src.src_msg_notification.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_msg_notification.category IS '分类：interaction-互动 territory-领地 monster-怪兽 system-系统';
COMMENT ON COLUMN src.src_msg_notification.title IS '标题';
COMMENT ON COLUMN src.src_msg_notification.body IS '正文';
COMMENT ON COLUMN src.src_msg_notification.data_json IS '跳转参数（territory_id、boss_id 等）';
COMMENT ON COLUMN src.src_msg_notification.read_time IS '已读时间（NULL 未读）';
COMMENT ON COLUMN src.src_msg_notification.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ord_membership.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ord_membership.plan_code IS '当前套餐代码';
COMMENT ON COLUMN src.src_ord_membership.channel IS '开通渠道（同订单支付渠道）';
COMMENT ON COLUMN src.src_ord_membership.expire_time IS '到期时间';
COMMENT ON COLUMN src.src_ord_membership.is_auto_renew IS '是否自动续费';
COMMENT ON COLUMN src.src_ord_membership.next_charge_time IS '下次扣费时间';
COMMENT ON COLUMN src.src_ord_membership.reminded_charge_time IS '已发送扣费提醒对应的扣费时间';
COMMENT ON COLUMN src.src_ord_membership.grace_end_time IS '续费失败后的权益保留截止时间';
COMMENT ON COLUMN src.src_ord_membership.apple_original_transaction_id IS 'Apple 原始交易ID（订阅续期关联）';
COMMENT ON COLUMN src.src_ord_membership.update_time IS '更新时间';
COMMENT ON COLUMN src.src_ord_order.order_no IS '订单号';
COMMENT ON COLUMN src.src_ord_order.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ord_order.plan_code IS '套餐代码（src_ord_plan.code）';
COMMENT ON COLUMN src.src_ord_order.plan_name IS '下单时的套餐名称';
COMMENT ON COLUMN src.src_ord_order.order_amt IS '订单金额（分）';
COMMENT ON COLUMN src.src_ord_order.channel IS '支付渠道：wechat_app-微信 alipay_app-支付宝 apple_iap-Apple 内购 mock-开发环境模拟 gift-后台赠送';
COMMENT ON COLUMN src.src_ord_order.order_type IS '订单类型：purchase-购买 renewal-续费 gift-赠送';
COMMENT ON COLUMN src.src_ord_order.status IS '状态：created-待支付 paid-已支付 refund_requested-退款申请中 refunded-已退款 closed-已关闭 renew_failed-续费失败';
COMMENT ON COLUMN src.src_ord_order.trade_no IS '渠道交易号';
COMMENT ON COLUMN src.src_ord_order.app_account_token IS 'Apple 内购 appAccountToken（关联订单）';
COMMENT ON COLUMN src.src_ord_order.pay_time IS '支付时间';
COMMENT ON COLUMN src.src_ord_order.refund_time IS '退款时间';
COMMENT ON COLUMN src.src_ord_order.refund_reason IS '退款原因';
COMMENT ON COLUMN src.src_ord_order.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ord_plan.code IS '套餐代码';
COMMENT ON COLUMN src.src_ord_plan.name IS '套餐名称';
COMMENT ON COLUMN src.src_ord_plan.period_type IS '周期：month-月 quarter-季 year-年';
COMMENT ON COLUMN src.src_ord_plan.is_auto_renew IS '是否连续包月/自动续费';
COMMENT ON COLUMN src.src_ord_plan.price_amt IS '售价（分）';
COMMENT ON COLUMN src.src_ord_plan.first_price_amt IS '首期价（分，NULL 无首期优惠）';
COMMENT ON COLUMN src.src_ord_plan.renew_price_amt IS '续费价（分）';
COMMENT ON COLUMN src.src_ord_plan.seats IS '可用人数（跑团版 5 人）';
COMMENT ON COLUMN src.src_ord_plan.is_recommended IS '是否推荐（开通页高亮）';
COMMENT ON COLUMN src.src_ord_plan.is_on_sale IS '是否在售';
COMMENT ON COLUMN src.src_ord_plan.sort IS '排序（小的在前）';
COMMENT ON COLUMN src.src_ord_plan.apple_product_id IS 'App Store 商品ID';
COMMENT ON COLUMN src.src_ord_plan.entitlements IS '权益 key 列表（guard_bonus、extra_energy 永远不可开启）';
COMMENT ON COLUMN src.src_ply_boss.id IS '主键';
COMMENT ON COLUMN src.src_ply_boss.boss_type IS '怪兽种类：sofa-沙发怪 bat-熬夜蝠 smog-雾霾怪 sugar-糖分怪';
COMMENT ON COLUMN src.src_ply_boss.name IS '怪兽名称';
COMMENT ON COLUMN src.src_ply_boss.level IS '首领等级';
COMMENT ON COLUMN src.src_ply_boss.location_name IS '出没地点描述';
COMMENT ON COLUMN src.src_ply_boss.center_geom IS '中心点（GCJ-02）';
COMMENT ON COLUMN src.src_ply_boss.radius_m IS '作用范围半径（米）';
COMMENT ON COLUMN src.src_ply_boss.hp_max IS '总血量';
COMMENT ON COLUMN src.src_ply_boss.hp IS '剩余血量';
COMMENT ON COLUMN src.src_ply_boss.status IS '状态：active-进行中 defeated-已击败 expired-已离开（到期）';
COMMENT ON COLUMN src.src_ply_boss.drops_json IS '投放时的掉落表快照（公示用）';
COMMENT ON COLUMN src.src_ply_boss.spawned_by IS '投放人（后台管理员ID，NULL 为系统自动投放）';
COMMENT ON COLUMN src.src_ply_boss.spawn_time IS '投放时间';
COMMENT ON COLUMN src.src_ply_boss.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_ply_boss.end_time IS '击败或离开的时间';
COMMENT ON COLUMN src.src_ply_boss_engage.boss_id IS '怪兽ID（src_ply_boss.id）';
COMMENT ON COLUMN src.src_ply_boss_engage.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_boss_engage.engage_end_time IS '出战有效截止时间';
COMMENT ON COLUMN src.src_ply_boss_hit.id IS '主键';
COMMENT ON COLUMN src.src_ply_boss_hit.boss_id IS '怪兽ID（src_ply_boss.id）';
COMMENT ON COLUMN src.src_ply_boss_hit.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_boss_hit.crew_id IS '跑团ID（src_soc_crew.id）';
COMMENT ON COLUMN src.src_ply_boss_hit.source IS '伤害来源：strike-合击 activity-运动';
COMMENT ON COLUMN src.src_ply_boss_hit.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_ply_boss_hit.damage IS '伤害值';
COMMENT ON COLUMN src.src_ply_boss_hit.energy_spent IS '花费能量（合击）';
COMMENT ON COLUMN src.src_ply_boss_hit.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_boss_reward.boss_id IS '怪兽ID（src_ply_boss.id）';
COMMENT ON COLUMN src.src_ply_boss_reward.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_boss_reward.rank IS '伤害排名';
COMMENT ON COLUMN src.src_ply_boss_reward.damage IS '总伤害';
COMMENT ON COLUMN src.src_ply_boss_reward.items_json IS '掉落物：item、kind、name、converted_energy（重复折算的能量）';
COMMENT ON COLUMN src.src_ply_boss_reward.energy IS '发放能量合计（掉落 + 到期返还）';
COMMENT ON COLUMN src.src_ply_boss_reward.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_chest.id IS '主键';
COMMENT ON COLUMN src.src_ply_chest.center_geom IS '位置（GCJ-02）';
COMMENT ON COLUMN src.src_ply_chest.radius_m IS '开启半径（米）';
COMMENT ON COLUMN src.src_ply_chest.energy_min IS '能量下限';
COMMENT ON COLUMN src.src_ply_chest.energy_max IS '能量上限';
COMMENT ON COLUMN src.src_ply_chest.source IS '来源：system-系统每日刷新 admin-运营投放';
COMMENT ON COLUMN src.src_ply_chest.placed_by IS '投放人（后台管理员ID）';
COMMENT ON COLUMN src.src_ply_chest.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_chest.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_ply_chest.remove_time IS '下架时间';
COMMENT ON COLUMN src.src_ply_chest_open.chest_id IS '宝箱ID（src_ply_chest.id）';
COMMENT ON COLUMN src.src_ply_chest_open.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_chest_open.energy IS '获得能量';
COMMENT ON COLUMN src.src_ply_chest_open.is_bonus IS '是否触发药剂师加成：true-能量翻倍';
COMMENT ON COLUMN src.src_ply_chest_open.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_ply_chest_open.open_time IS '开启时间';
COMMENT ON COLUMN src.src_ply_codex_item.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_codex_item.item_type IS '收集类型：role-角色 blueprint-建筑图纸 egg-伙伴蛋 companion-已孵化伙伴 monster-怪兽 medal-奖牌';
COMMENT ON COLUMN src.src_ply_codex_item.item IS '收集项 key';
COMMENT ON COLUMN src.src_ply_codex_item.progress IS '进度（伙伴蛋为已跑公里数）';
COMMENT ON COLUMN src.src_ply_codex_item.obtain_time IS '获得时间';
COMMENT ON COLUMN src.src_ply_companion_growth.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_companion_growth.companion IS '伙伴 key';
COMMENT ON COLUMN src.src_ply_companion_growth.exp IS '累计经验';
COMMENT ON COLUMN src.src_ply_companion_growth.meters IS '累计陪跑距离（米）';
COMMENT ON COLUMN src.src_ply_energy_ledger.id IS '主键';
COMMENT ON COLUMN src.src_ply_energy_ledger.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_energy_ledger.ledger_date IS '业务日期（Asia/Shanghai）';
COMMENT ON COLUMN src.src_ply_energy_ledger.delta IS '能量变化（正数增加，负数减少）';
COMMENT ON COLUMN src.src_ply_energy_ledger.reason IS '原因：activity-运动 build-建造 territory_yield-领地每日产出 rollback-作弊回滚 boss_strike-合击 boss_reward-怪兽奖励 chest-宝箱 task-赛季任务 campaign-限时活动 route-城市定向 relay-跑团接力 companion_feed-喂伙伴';
COMMENT ON COLUMN src.src_ply_energy_ledger.ref_id IS '关联记录ID（运动、领地、怪兽等，视 reason 而定）';
COMMENT ON COLUMN src.src_ply_energy_ledger.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_league_result.week_start_date IS '所在周的周一（Asia/Shanghai）';
COMMENT ON COLUMN src.src_ply_league_result.district IS '城区';
COMMENT ON COLUMN src.src_ply_league_result.crew_id IS '跑团ID（src_soc_crew.id）';
COMMENT ON COLUMN src.src_ply_league_result.rank IS '名次';
COMMENT ON COLUMN src.src_ply_league_result.score_m2 IS '本周成员新圈面积（平方米）';
COMMENT ON COLUMN src.src_ply_league_result.active_members IS '本周运动过的成员数';
COMMENT ON COLUMN src.src_ply_route.id IS '主键';
COMMENT ON COLUMN src.src_ply_route.name IS '路线名称';
COMMENT ON COLUMN src.src_ply_route.description IS '说明';
COMMENT ON COLUMN src.src_ply_route.checkpoints_json IS '有序打卡点：name、lat、lng、radius_m';
COMMENT ON COLUMN src.src_ply_route.bbox IS '范围（预留）';
COMMENT ON COLUMN src.src_ply_route.reward_energy IS '完成奖励能量';
COMMENT ON COLUMN src.src_ply_route.start_time IS '开始时间';
COMMENT ON COLUMN src.src_ply_route.end_time IS '结束时间';
COMMENT ON COLUMN src.src_ply_route.created_by IS '创建人（后台管理员ID，src_sys_admin.id）';
COMMENT ON COLUMN src.src_ply_route.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_route_progress.route_id IS '路线ID（src_ply_route.id）';
COMMENT ON COLUMN src.src_ply_route_progress.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_route_progress.next_index IS '下一个要到达的打卡点序号';
COMMENT ON COLUMN src.src_ply_route_progress.complete_time IS '完成时间';
COMMENT ON COLUMN src.src_ply_season.id IS '主键';
COMMENT ON COLUMN src.src_ply_season.name IS '赛季名称';
COMMENT ON COLUMN src.src_ply_season.start_time IS '开始时间';
COMMENT ON COLUMN src.src_ply_season.end_time IS '结束时间';
COMMENT ON COLUMN src.src_ply_season.settle_time IS '结算时间（NULL 为未结算）';
COMMENT ON COLUMN src.src_ply_season.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ply_season_result.season_id IS '赛季ID（src_ply_season.id）';
COMMENT ON COLUMN src.src_ply_season_result.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_season_result.area_m2 IS '赛季内新圈面积（平方米）';
COMMENT ON COLUMN src.src_ply_season_result.rank IS '排名';
COMMENT ON COLUMN src.src_ply_season_result.tier IS '最终段位：青铜 白银 黄金 铂金 钻石';
COMMENT ON COLUMN src.src_ply_task_done.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_task_done.task_key IS '任务 key（见玩法配置 season_tasks）';
COMMENT ON COLUMN src.src_ply_task_done.week_start_date IS '所在周的周一（Asia/Shanghai）';
COMMENT ON COLUMN src.src_ply_task_done.reward_energy IS '奖励能量';
COMMENT ON COLUMN src.src_ply_task_done.complete_time IS '完成时间';
COMMENT ON COLUMN src.src_ply_user_monster.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ply_user_monster.boss_type IS '怪兽种类：sofa-沙发怪 bat-熬夜蝠 smog-雾霾怪 sugar-糖分怪';
COMMENT ON COLUMN src.src_ply_user_monster.strikes IS '出手次数';
COMMENT ON COLUMN src.src_ply_user_monster.defeats IS '参与击败次数';
COMMENT ON COLUMN src.src_ply_user_monster.best_rank IS '最高伤害排名';
COMMENT ON COLUMN src.src_ris_alert.id IS '主键';
COMMENT ON COLUMN src.src_ris_alert.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_ris_alert.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ris_alert.alert_type IS '告警类型：speed-速度异常 mock_location-模拟定位 teleport-轨迹瞬移 device_tamper-设备异常 missing_device_data-缺少设备信息 multi_account-多账号同设备';
COMMENT ON COLUMN src.src_ris_alert.confidence IS '置信度（0–1）';
COMMENT ON COLUMN src.src_ris_alert.detail IS '告警说明';
COMMENT ON COLUMN src.src_ris_alert.status IS '处理状态：open-待处理 resolved-已处理';
COMMENT ON COLUMN src.src_ris_alert.resolution IS '处置方式：void-作废回滚 warn-警告 ban_30d-封禁30天 false_positive-误报放行 auto_void-系统自动作废';
COMMENT ON COLUMN src.src_ris_alert.note IS '处置备注';
COMMENT ON COLUMN src.src_ris_alert.resolved_by IS '处置人（后台管理员ID）';
COMMENT ON COLUMN src.src_ris_alert.resolve_time IS '处置时间';
COMMENT ON COLUMN src.src_ris_alert.create_time IS '创建时间';
COMMENT ON COLUMN src.src_soc_crew.id IS '主键';
COMMENT ON COLUMN src.src_soc_crew.name IS '跑团名称';
COMMENT ON COLUMN src.src_soc_crew.avatar_url IS '头像地址';
COMMENT ON COLUMN src.src_soc_crew.district IS '所在城区';
COMMENT ON COLUMN src.src_soc_crew.join_mode IS '加入方式：open-公开 apply-申请 invite-仅邀请';
COMMENT ON COLUMN src.src_soc_crew.leader_id IS '团长用户ID';
COMMENT ON COLUMN src.src_soc_crew.create_time IS '创建时间';
COMMENT ON COLUMN src.src_soc_crew_apply.crew_id IS '跑团ID（src_soc_crew.id）';
COMMENT ON COLUMN src.src_soc_crew_apply.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_soc_crew_apply.create_time IS '创建时间';
COMMENT ON COLUMN src.src_soc_crew_member.crew_id IS '跑团ID（src_soc_crew.id）';
COMMENT ON COLUMN src.src_soc_crew_member.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_soc_crew_member.join_time IS '加入时间';
COMMENT ON COLUMN src.src_soc_relay.id IS '主键';
COMMENT ON COLUMN src.src_soc_relay.crew_id IS '跑团ID（src_soc_crew.id）';
COMMENT ON COLUMN src.src_soc_relay.legs IS '总棒数';
COMMENT ON COLUMN src.src_soc_relay.leg_km IS '单棒距离（公里）';
COMMENT ON COLUMN src.src_soc_relay.status IS '状态：running-进行中 completed-已完成 expired-已过期';
COMMENT ON COLUMN src.src_soc_relay.started_by IS '发起人（团长）用户ID';
COMMENT ON COLUMN src.src_soc_relay.start_time IS '开始时间';
COMMENT ON COLUMN src.src_soc_relay.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_soc_relay.complete_time IS '完成时间';
COMMENT ON COLUMN src.src_soc_relay_run.relay_id IS '接力ID（src_soc_relay.id）';
COMMENT ON COLUMN src.src_soc_relay_run.leg IS '第几棒';
COMMENT ON COLUMN src.src_soc_relay_run.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_soc_relay_run.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_soc_relay_run.distance_m IS '这一棒的运动距离（米）';
COMMENT ON COLUMN src.src_soc_relay_run.run_time IS '完成时间';
COMMENT ON COLUMN src.src_sys_admin.id IS '主键';
COMMENT ON COLUMN src.src_sys_admin.username IS '用户名';
COMMENT ON COLUMN src.src_sys_admin.password_hash IS '密码哈希（bcrypt）';
COMMENT ON COLUMN src.src_sys_admin.role IS '角色：admin-管理员 ops-运营 reviewer-审核员 merchant-商户对接';
COMMENT ON COLUMN src.src_sys_admin.is_disabled IS '是否停用';
COMMENT ON COLUMN src.src_sys_admin.create_time IS '创建时间';
COMMENT ON COLUMN src.src_sys_audit_log.id IS '主键';
COMMENT ON COLUMN src.src_sys_audit_log.admin_id IS '管理员ID（src_sys_admin.id）';
COMMENT ON COLUMN src.src_sys_audit_log.action IS '操作（如 user.ban、order.refund）';
COMMENT ON COLUMN src.src_sys_audit_log.target IS '操作对象（如 user:12）';
COMMENT ON COLUMN src.src_sys_audit_log.detail_json IS '操作详情';
COMMENT ON COLUMN src.src_sys_audit_log.create_time IS '创建时间';
COMMENT ON COLUMN src.src_sys_gameplay_config.id IS '主键';
COMMENT ON COLUMN src.src_sys_gameplay_config.version IS '版本号（如 v3.12）';
COMMENT ON COLUMN src.src_sys_gameplay_config.config_json IS '完整玩法配置';
COMMENT ON COLUMN src.src_sys_gameplay_config.rollout_pct IS '灰度比例（1–100）';
COMMENT ON COLUMN src.src_sys_gameplay_config.note IS '发布说明';
COMMENT ON COLUMN src.src_sys_gameplay_config.published_by IS '发布人（后台管理员ID）';
COMMENT ON COLUMN src.src_sys_gameplay_config.publish_time IS '发布时间';
COMMENT ON COLUMN src.src_sys_gameplay_config.rollback_time IS '撤回时间（NULL 有效）';
COMMENT ON COLUMN src.src_sys_setting.setting_key IS '设置项：risk_rules-风控规则 territory_yield_day-领地产出已发放日期 chests_day-宝箱已刷新日期 league_settled-联赛已结算周';
COMMENT ON COLUMN src.src_sys_setting.setting_value IS '设置值（JSON）';
COMMENT ON COLUMN src.src_sys_setting.update_time IS '更新时间';
COMMENT ON COLUMN src.src_ter_building.territory_id IS '领地ID（src_ter_territory.id）';
COMMENT ON COLUMN src.src_ter_building.slot IS '建造位（0 开始，每块领地 6 个）';
COMMENT ON COLUMN src.src_ter_building.building IS '建筑 key（见玩法配置 buildings）';
COMMENT ON COLUMN src.src_ter_building.built_by IS '建造人用户ID';
COMMENT ON COLUMN src.src_ter_building.build_time IS '建造时间';
COMMENT ON COLUMN src.src_ter_defense.territory_id IS '领地ID（src_ter_territory.id）';
COMMENT ON COLUMN src.src_ter_defense.attacker_id IS '攻击者用户ID';
COMMENT ON COLUMN src.src_ter_defense.open_time IS '窗口打开时间（被攻击时间）';
COMMENT ON COLUMN src.src_ter_defense.deadline_time IS '加固截止时间';
COMMENT ON COLUMN src.src_ter_event.id IS '主键';
COMMENT ON COLUMN src.src_ter_event.territory_id IS '领地ID（src_ter_territory.id）';
COMMENT ON COLUMN src.src_ter_event.activity_id IS '运动记录ID（src_act_activity.id）';
COMMENT ON COLUMN src.src_ter_event.event_type IS '事件类型：claim-圈地 capture-抢下一块 capture_whole-整块夺取 cut-被切走一部分 weaken-被削弱 build-建造 reinforce-加固 freeze-冻结 unfreeze-解冻 reset-重置为无主 rollback-回滚 admin_guard-后台改守卫值 owner_deleted-主人注销';
COMMENT ON COLUMN src.src_ter_event.actor_user_id IS '操作用户ID';
COMMENT ON COLUMN src.src_ter_event.prev_owner_id IS '变更前归属用户ID';
COMMENT ON COLUMN src.src_ter_event.new_owner_id IS '变更后归属用户ID';
COMMENT ON COLUMN src.src_ter_event.prev_guard IS '变更前守卫值';
COMMENT ON COLUMN src.src_ter_event.new_guard IS '变更后守卫值';
COMMENT ON COLUMN src.src_ter_event.prev_area_geom IS '变更前范围（用于回滚被切走的部分）';
COMMENT ON COLUMN src.src_ter_event.prev_state_json IS '整块夺取或重置前的建筑、驻扎和跑团（用于回滚）';
COMMENT ON COLUMN src.src_ter_event.admin_id IS '后台操作管理员ID';
COMMENT ON COLUMN src.src_ter_event.create_time IS '创建时间';
COMMENT ON COLUMN src.src_ter_station.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_ter_station.role IS '角色 key（见玩法配置 roles）';
COMMENT ON COLUMN src.src_ter_station.territory_id IS '领地ID（src_ter_territory.id）';
COMMENT ON COLUMN src.src_ter_territory.id IS '主键';
COMMENT ON COLUMN src.src_ter_territory.name IS '领地名称（NULL 时显示「领地 #ID」）';
COMMENT ON COLUMN src.src_ter_territory.owner_user_id IS '归属用户ID（NULL 表示无主）';
COMMENT ON COLUMN src.src_ter_territory.owner_crew_id IS '归属跑团ID（圈地时圈地人所在跑团）';
COMMENT ON COLUMN src.src_ter_territory.area_geom IS '领地范围（MultiPolygon，GCJ-02）';
COMMENT ON COLUMN src.src_ter_territory.area_m2 IS '面积（平方米）';
COMMENT ON COLUMN src.src_ter_territory.guard IS '当前守卫值';
COMMENT ON COLUMN src.src_ter_territory.is_frozen IS '是否冻结：true-冻结（不可被抢、不可建设）';
COMMENT ON COLUMN src.src_ter_territory.source_activity IS '最近一次占领它的运动记录ID';
COMMENT ON COLUMN src.src_ter_territory.capture_time IS '被当前主人占领的时间';
COMMENT ON COLUMN src.src_ter_territory.update_time IS '更新时间';
COMMENT ON COLUMN src.src_usr_device.device_id IS '设备ID（客户端生成）';
COMMENT ON COLUMN src.src_usr_device.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_usr_device.last_seen_time IS '最近一次出现时间';
COMMENT ON COLUMN src.src_usr_identity.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_usr_identity.provider IS '登录方式：wechat-微信 apple-Apple';
COMMENT ON COLUMN src.src_usr_identity.provider_uid IS '第三方用户标识（openid / sub）';
COMMENT ON COLUMN src.src_usr_identity.union_id IS '微信 unionid（多端打通）';
COMMENT ON COLUMN src.src_usr_identity.create_time IS '创建时间';
COMMENT ON COLUMN src.src_usr_refresh_token.token_hash IS '令牌哈希（SHA-256）';
COMMENT ON COLUMN src.src_usr_refresh_token.family IS '令牌族ID（同一次登录的轮换链）';
COMMENT ON COLUMN src.src_usr_refresh_token.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_usr_refresh_token.device_id IS '设备ID';
COMMENT ON COLUMN src.src_usr_refresh_token.expire_time IS '过期时间';
COMMENT ON COLUMN src.src_usr_refresh_token.use_time IS '已轮换（使用）时间';
COMMENT ON COLUMN src.src_usr_refresh_token.revoke_time IS '作废时间';
COMMENT ON COLUMN src.src_usr_refresh_token.create_time IS '创建时间';
COMMENT ON COLUMN src.src_usr_stat.user_id IS '用户ID（src_usr_user.id）';
COMMENT ON COLUMN src.src_usr_stat.stat_key IS '计数项：defends-守地成功次数 loops_single-单次运动最多圈地块数 boss_defeats-参与击败怪兽次数 chests-开宝箱数 routes-完成定向路线数';
COMMENT ON COLUMN src.src_usr_stat.stat_value IS '计数值';
COMMENT ON COLUMN src.src_usr_user.id IS '主键';
COMMENT ON COLUMN src.src_usr_user.phone_enc IS '手机号密文（AES-256-GCM）';
COMMENT ON COLUMN src.src_usr_user.phone_hash IS '手机号查询哈希（HMAC-SHA256）';
COMMENT ON COLUMN src.src_usr_user.phone_last4 IS '手机号后4位（后台按尾号搜索）';
COMMENT ON COLUMN src.src_usr_user.nickname IS '昵称';
COMMENT ON COLUMN src.src_usr_user.avatar_url IS '头像地址';
COMMENT ON COLUMN src.src_usr_user.source IS '注册来源：sms-短信 oneclick-一键登录 wechat-微信 apple-Apple';
COMMENT ON COLUMN src.src_usr_user.energy IS '当前能量余额';
COMMENT ON COLUMN src.src_usr_user.energy_earned_total IS '累计通过运动获得的能量（用于计算等级）';
COMMENT ON COLUMN src.src_usr_user.is_realname_verified IS '是否已实名：true-已实名 false-未实名';
COMMENT ON COLUMN src.src_usr_user.is_adult IS '是否成年：true-成年 false-未成年 NULL-未实名';
COMMENT ON COLUMN src.src_usr_user.birth_year IS '出生年份（实名后记录，不存身份证号）';
COMMENT ON COLUMN src.src_usr_user.status IS '账号状态：active-正常 banned-封禁 deleting-注销冷静期 deleted-已注销';
COMMENT ON COLUMN src.src_usr_user.mute_end_time IS '禁言截止时间';
COMMENT ON COLUMN src.src_usr_user.ban_end_time IS '封禁截止时间（NULL 表示永久）';
COMMENT ON COLUMN src.src_usr_user.delete_time IS '注销生效时间（冷静期结束）';
COMMENT ON COLUMN src.src_usr_user.consents_json IS '隐私授权：privacy_version 隐私政策版本，location 定位授权，health 运动健康授权';
COMMENT ON COLUMN src.src_usr_user.settings_json IS '隐私设置：track_visibility 轨迹可见范围，hide_endpoints 隐藏起终点，show_avatar_on_map 地图显示头像，personalized 个性化推荐';
COMMENT ON COLUMN src.src_usr_user.escort_companion_key IS '当前陪跑伙伴（伙伴 key）';
COMMENT ON COLUMN src.src_usr_user.last_login_time IS '最近登录时间';
COMMENT ON COLUMN src.src_usr_user.create_time IS '创建时间';
COMMENT ON TABLE src.src_act_track_point_default IS '轨迹点默认分区（未建按月分区时落在这里）';
