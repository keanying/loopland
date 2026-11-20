-- Loopland V1 schema.
--
-- Coordinates are GCJ-02 as delivered by the AMap SDK, stored with SRID 4326
-- so PostGIS functions work. Every client and the admin map use the same
-- datum and areas are computed on geography, so the offset has no practical
-- effect. Never mix in raw WGS84 points.

CREATE EXTENSION IF NOT EXISTS postgis;

-- Normalise any geometry to a valid MultiPolygon (empty when nothing is left).
CREATE OR REPLACE FUNCTION lp_clean(g geometry) RETURNS geometry
LANGUAGE sql IMMUTABLE AS $$
  SELECT ST_SetSRID(ST_Multi(ST_CollectionExtract(ST_MakeValid(g), 3)), 4326)
$$;

CREATE OR REPLACE FUNCTION lp_area(g geometry) RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(ST_Area(g::geography), 0)
$$;

-- ---------------------------------------------------------------- accounts

CREATE TABLE users (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone_enc           BYTEA,                -- AES-GCM, key from LOOPLAND_DATA_KEY
    phone_hash          BYTEA UNIQUE,         -- HMAC for lookup
    phone_last4         TEXT,
    nickname            TEXT        NOT NULL,
    avatar_url          TEXT,
    source              TEXT        NOT NULL, -- first login provider
    energy              INT         NOT NULL DEFAULT 0 CHECK (energy >= 0),
    energy_earned_total BIGINT      NOT NULL DEFAULT 0,
    realname_verified   BOOLEAN     NOT NULL DEFAULT false,
    is_adult            BOOLEAN,
    birth_year          INT,
    status              TEXT        NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'banned', 'deleting', 'deleted')),
    muted_until         TIMESTAMPTZ,
    banned_until        TIMESTAMPTZ,
    delete_after        TIMESTAMPTZ,
    consents            JSONB       NOT NULL DEFAULT '{}',
    settings            JSONB       NOT NULL DEFAULT '{"track_visibility":"public","hide_endpoints":true,"show_avatar_on_map":true,"personalized":true}',
    escort_companion    TEXT,
    last_login_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX users_phone_last4 ON users (phone_last4);
CREATE INDEX users_created ON users (created_at);

CREATE TABLE user_identities (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    provider        TEXT        NOT NULL,     -- wechat | apple (phone lives on users)
    provider_uid    TEXT        NOT NULL,
    union_id        TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, provider_uid)
);
CREATE INDEX user_identities_user ON user_identities (user_id);
CREATE UNIQUE INDEX user_identities_union ON user_identities (provider, union_id) WHERE union_id IS NOT NULL;

CREATE TABLE refresh_tokens (
    token_hash      BYTEA       PRIMARY KEY,
    family          UUID        NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id       TEXT,
    expires_at      TIMESTAMPTZ NOT NULL,
    used_at         TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_family ON refresh_tokens (family);
CREATE INDEX refresh_tokens_user ON refresh_tokens (user_id);

-- Every device id seen per user, for the 多账号同设备 rule.
CREATE TABLE user_devices (
    device_id       TEXT        NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, user_id)
);

-- ---------------------------------------------------------------- crews

CREATE TABLE crews (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL UNIQUE,
    avatar_url      TEXT,
    district        TEXT        NOT NULL,
    join_mode       TEXT        NOT NULL DEFAULT 'open' CHECK (join_mode IN ('open', 'apply', 'invite')),
    leader_id       BIGINT      NOT NULL REFERENCES users (id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE crew_members (
    crew_id         BIGINT      NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (crew_id, user_id),
    UNIQUE (user_id)
);

CREATE TABLE crew_applications (
    crew_id         BIGINT      NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (crew_id, user_id)
);

-- ---------------------------------------------------------------- energy

CREATE TABLE energy_ledger (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    day             DATE        NOT NULL,     -- Asia/Shanghai
    delta           INT         NOT NULL,
    reason          TEXT        NOT NULL,     -- activity | build | territory_yield | rollback | admin
    ref_id          BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX energy_ledger_user_day ON energy_ledger (user_id, day);

-- ---------------------------------------------------------------- activities

CREATE TABLE activities (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    client_id       UUID        NOT NULL,
    sport           TEXT        NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL,
    ended_at        TIMESTAMPTZ NOT NULL,
    distance_m      DOUBLE PRECISION NOT NULL DEFAULT 0,
    duration_s      INT         NOT NULL DEFAULT 0,
    amount          DOUBLE PRECISION NOT NULL DEFAULT 0,
    energy_raw      INT         NOT NULL DEFAULT 0,
    energy_granted  INT         NOT NULL DEFAULT 0,
    claimed_area_m2 DOUBLE PRECISION NOT NULL DEFAULT 0,
    track           geometry(LineString, 4326),
    goal            JSONB,
    device          JSONB,
    wearable        JSONB,
    status          TEXT        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'settled', 'voided', 'review')),
    result          JSONB,                    -- the settlement returned to the client
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, client_id)
);
CREATE INDEX activities_user_time ON activities (user_id, started_at DESC);
CREATE INDEX activities_created ON activities (created_at);

CREATE TABLE track_points (
    activity_id     BIGINT      NOT NULL,
    seq             INT         NOT NULL,
    recorded_at     TIMESTAMPTZ NOT NULL,
    lat             DOUBLE PRECISION NOT NULL,
    lng             DOUBLE PRECISION NOT NULL,
    accuracy_m      REAL,
    speed_mps       REAL,
    heart_rate      SMALLINT,
    cadence         SMALLINT,
    source          TEXT,
    PRIMARY KEY (recorded_at, activity_id, seq)
) PARTITION BY RANGE (recorded_at);
CREATE TABLE track_points_default PARTITION OF track_points DEFAULT;
CREATE INDEX track_points_activity ON track_points (activity_id, seq);

-- Cumulative amount per sport, drives 角色招募.
CREATE TABLE user_sport_totals (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sport           TEXT        NOT NULL,
    amount          DOUBLE PRECISION NOT NULL DEFAULT 0,
    distance_m      DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, sport)
);

-- ---------------------------------------------------------------- territory

CREATE TABLE territories (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT,
    owner_user_id   BIGINT      REFERENCES users (id),
    owner_crew_id   BIGINT      REFERENCES crews (id) ON DELETE SET NULL,
    geom            geometry(MultiPolygon, 4326) NOT NULL,
    area_m2         DOUBLE PRECISION NOT NULL,
    guard           INT         NOT NULL DEFAULT 0 CHECK (guard >= 0),
    frozen          BOOLEAN     NOT NULL DEFAULT false,
    source_activity BIGINT      REFERENCES activities (id) ON DELETE SET NULL,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territories_geom ON territories USING GIST (geom);
CREATE INDEX territories_owner ON territories (owner_user_id);
CREATE INDEX territories_crew ON territories (owner_crew_id);

-- Every change, so a voided activity can be rolled back and admins can audit.
CREATE TABLE territory_events (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    territory_id    BIGINT      NOT NULL REFERENCES territories (id) ON DELETE CASCADE,
    activity_id     BIGINT      REFERENCES activities (id) ON DELETE SET NULL,
    kind            TEXT        NOT NULL CHECK (kind IN (
                        'claim', 'capture', 'capture_whole', 'cut', 'weaken', 'build',
                        'freeze', 'unfreeze', 'reset', 'rollback', 'admin_guard', 'owner_deleted')),
    actor_user_id   BIGINT,
    prev_owner_id   BIGINT,
    new_owner_id    BIGINT,
    prev_guard      INT,
    new_guard       INT,
    prev_geom       geometry(MultiPolygon, 4326),
    prev_state      JSONB,                    -- buildings/stationed/crew before a whole capture
    admin_id        BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territory_events_territory ON territory_events (territory_id, id DESC);
CREATE INDEX territory_events_activity ON territory_events (activity_id);
CREATE INDEX territory_events_created ON territory_events (created_at);

CREATE TABLE territory_buildings (
    territory_id    BIGINT      NOT NULL REFERENCES territories (id) ON DELETE CASCADE,
    slot            SMALLINT    NOT NULL CHECK (slot BETWEEN 0 AND 15),
    building        TEXT        NOT NULL,
    built_by        BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    built_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (territory_id, slot)
);

CREATE TABLE territory_stationed (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role            TEXT        NOT NULL,
    territory_id    BIGINT      NOT NULL REFERENCES territories (id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role)
);
CREATE INDEX territory_stationed_territory ON territory_stationed (territory_id);

-- ---------------------------------------------------------------- codex

CREATE TABLE codex_items (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind            TEXT        NOT NULL CHECK (kind IN ('role', 'blueprint', 'egg', 'companion', 'monster', 'medal')),
    item            TEXT        NOT NULL,
    progress        DOUBLE PRECISION NOT NULL DEFAULT 0,
    obtained_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, kind, item)
);

-- ---------------------------------------------------------------- risk

CREATE TABLE risk_alerts (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    activity_id     BIGINT      REFERENCES activities (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    type            TEXT        NOT NULL,
    confidence      REAL        NOT NULL,
    detail          TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
    resolution      TEXT,
    note            TEXT,
    resolved_by     BIGINT,
    resolved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX risk_alerts_status ON risk_alerts (status, confidence DESC);
CREATE INDEX risk_alerts_user ON risk_alerts (user_id);

-- ---------------------------------------------------------------- billing

CREATE TABLE plans (
    code            TEXT        PRIMARY KEY,
    name            TEXT        NOT NULL,
    period          TEXT        NOT NULL CHECK (period IN ('month', 'quarter', 'year')),
    auto_renew      BOOLEAN     NOT NULL DEFAULT false,
    price_fen       INT         NOT NULL CHECK (price_fen > 0),
    first_price_fen INT         CHECK (first_price_fen > 0),
    renew_price_fen INT         NOT NULL CHECK (renew_price_fen > 0),
    seats           INT         NOT NULL DEFAULT 1,
    recommended     BOOLEAN     NOT NULL DEFAULT false,
    on_sale         BOOLEAN     NOT NULL DEFAULT true,
    sort            INT         NOT NULL DEFAULT 0,
    apple_product_id TEXT,
    entitlements    TEXT[]      NOT NULL DEFAULT '{}',
    CHECK (NOT ('guard_bonus' = ANY (entitlements) OR 'extra_energy' = ANY (entitlements)))
);

CREATE TABLE orders (
    order_no        TEXT        PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    plan_code       TEXT        NOT NULL REFERENCES plans (code),
    plan_name       TEXT        NOT NULL,
    amount_fen      INT         NOT NULL,
    channel         TEXT        NOT NULL,
    kind            TEXT        NOT NULL DEFAULT 'purchase' CHECK (kind IN ('purchase', 'renewal', 'gift')),
    status          TEXT        NOT NULL DEFAULT 'created'
                    CHECK (status IN ('created', 'paid', 'refund_requested', 'refunded', 'closed', 'renew_failed')),
    trade_no        TEXT,
    app_account_token UUID,
    paid_at         TIMESTAMPTZ,
    refunded_at     TIMESTAMPTZ,
    refund_reason   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX orders_user ON orders (user_id, created_at DESC);
CREATE INDEX orders_status ON orders (status, created_at DESC);
CREATE UNIQUE INDEX orders_trade ON orders (channel, trade_no) WHERE trade_no IS NOT NULL;
CREATE UNIQUE INDEX orders_apple_token ON orders (app_account_token) WHERE app_account_token IS NOT NULL;

CREATE TABLE memberships (
    user_id         BIGINT      PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    plan_code       TEXT        NOT NULL REFERENCES plans (code),
    channel         TEXT        NOT NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    auto_renew      BOOLEAN     NOT NULL DEFAULT false,
    next_charge_at  TIMESTAMPTZ,
    reminded_for    TIMESTAMPTZ,              -- next_charge_at that the 5-day reminder was sent for
    grace_until     TIMESTAMPTZ,              -- 续费失败保留权益 3 天
    apple_original_transaction_id TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- inbox

CREATE TABLE notifications (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    category        TEXT        NOT NULL CHECK (category IN ('interaction', 'territory', 'monster', 'system')),
    title           TEXT        NOT NULL,
    body            TEXT        NOT NULL,
    data            JSONB       NOT NULL DEFAULT '{}',
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX notifications_user ON notifications (user_id, id DESC);

-- ---------------------------------------------------------------- config

CREATE TABLE gameplay_configs (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version         TEXT        NOT NULL UNIQUE,
    body            JSONB       NOT NULL,
    rollout_pct     SMALLINT    NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 1 AND 100),
    note            TEXT,
    published_by    BIGINT,
    published_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    rolled_back_at  TIMESTAMPTZ
);

-- Small key/value settings: risk rules, job bookkeeping.
CREATE TABLE settings (
    key             TEXT        PRIMARY KEY,
    value           JSONB       NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- admin

CREATE TABLE admin_users (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username        TEXT        NOT NULL UNIQUE,
    password_hash   TEXT        NOT NULL,
    role            TEXT        NOT NULL CHECK (role IN ('admin', 'ops', 'reviewer', 'merchant')),
    disabled        BOOLEAN     NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit_logs (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id        BIGINT      NOT NULL REFERENCES admin_users (id),
    action          TEXT        NOT NULL,
    target          TEXT        NOT NULL,
    detail          JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_created ON audit_logs (id DESC);

-- ---------------------------------------------------------------- seed

INSERT INTO plans (code, name, period, auto_renew, price_fen, first_price_fen, renew_price_fen, seats, recommended, sort, apple_product_id, entitlements) VALUES
 ('auto_month', '连续包月', 'month',   true,  1800, 1500, 1800, 1, true,  1, 'com.loopland.member.auto_month', '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('month',      '月卡',     'month',   false, 1800, NULL, 1800, 1, false, 2, 'com.loopland.member.month',      '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('quarter',    '季卡',     'quarter', false, 4500, NULL, 4500, 1, false, 3, 'com.loopland.member.quarter',    '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('year',       '年卡',     'year',    false, 16800, NULL, 16800, 1, false, 4, 'com.loopland.member.year',     '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export}'),
 ('crew_year',  '跑团版',   'year',    false, 29800, NULL, 29800, 5, false, 5, 'com.loopland.member.crew_year', '{map_styles,advanced_stats,ai_coach_unlimited,exclusive_skins,hd_replay_export,crew_tools}');

INSERT INTO settings (key, value) VALUES
 ('risk_rules', '{"run_max_kmh":20,"ride_max_kmh":45,"hike_max_kmh":12,"walk_max_kmh":10,"teleport_m":500,"gap_s":30,"require_wearable_for_events":true}');
