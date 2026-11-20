-- Loopland initial schema: accounts, crews, activities, track points, territory.
--
-- Coordinates are GCJ-02 as delivered by the AMap SDK and are stored with
-- SRID 4326 so PostGIS functions work; every client and the admin map use the
-- same datum, and areas are computed on geography, so the offset has no
-- practical effect. Never mix in raw WGS84 points.

CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE users (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone_enc       BYTEA,                 -- field-level encrypted (技术选型 · 安全)
    phone_last4     TEXT,                  -- for admin search by 手机尾号
    nickname        TEXT        NOT NULL,
    avatar_url      TEXT,
    level           INT         NOT NULL DEFAULT 1,
    is_adult        BOOLEAN,               -- NULL until 实名
    energy          INT         NOT NULL DEFAULT 0 CHECK (energy >= 0),
    status          TEXT        NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'muted', 'banned', 'deleting')),
    delete_after    TIMESTAMPTZ,           -- 注销冷静期 7 天
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE crews (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL,
    avatar_url      TEXT,
    district        TEXT        NOT NULL,  -- 所在城区，用于城区联赛
    join_mode       TEXT        NOT NULL DEFAULT 'open'
                    CHECK (join_mode IN ('open', 'apply', 'invite')),
    leader_id       BIGINT      NOT NULL REFERENCES users (id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE crew_members (
    crew_id         BIGINT      NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (crew_id, user_id),
    UNIQUE (user_id)                       -- one crew per user
);

-- Daily energy ledger: the 600/day cap is enforced per (user, day).
CREATE TABLE energy_ledger (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id),
    day             DATE        NOT NULL,
    delta           INT         NOT NULL,
    reason          TEXT        NOT NULL,  -- activity | build | boss_strike | territory_yield | refund | rollback
    ref_id          BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX energy_ledger_user_day ON energy_ledger (user_id, day);

CREATE TABLE activities (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id         BIGINT      NOT NULL REFERENCES users (id),
    sport           TEXT        NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL,
    ended_at        TIMESTAMPTZ NOT NULL,
    distance_m      DOUBLE PRECISION NOT NULL DEFAULT 0,
    duration_s      INT         NOT NULL DEFAULT 0,
    amount          DOUBLE PRECISION NOT NULL DEFAULT 0,  -- in the energy rule's unit
    raw_energy      INT         NOT NULL DEFAULT 0,
    granted_energy  INT         NOT NULL DEFAULT 0,
    track           geometry(LineString, 4326),
    -- pending → settled | voided (风控作废，领地回滚) | review (人工队列)
    status          TEXT        NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'settled', 'voided', 'review')),
    device_id       TEXT,
    has_wearable    BOOLEAN     NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX activities_user_time ON activities (user_id, started_at DESC);

-- Raw GPS points, partitioned by month; moves to ClickHouse at scale.
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
    source          TEXT,                  -- gps | network | mock (mock → 风控)
    PRIMARY KEY (recorded_at, activity_id, seq)
) PARTITION BY RANGE (recorded_at);
CREATE TABLE track_points_default PARTITION OF track_points DEFAULT;

CREATE TABLE territories (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_user_id   BIGINT      REFERENCES users (id),   -- NULL = 无主
    owner_crew_id   BIGINT      REFERENCES crews (id),
    geom            geometry(MultiPolygon, 4326) NOT NULL CHECK (ST_IsValid(geom)),
    area_m2         DOUBLE PRECISION GENERATED ALWAYS AS (ST_Area(geom::geography)) STORED,
    guard           INT         NOT NULL DEFAULT 0 CHECK (guard BETWEEN 0 AND 100000),
    h3_cell         TEXT,                  -- map shard for viewport loading
    frozen          BOOLEAN     NOT NULL DEFAULT false,
    skin            TEXT,
    source_activity BIGINT      REFERENCES activities (id),
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territories_geom ON territories USING GIST (geom);
CREATE INDEX territories_owner ON territories (owner_user_id);
CREATE INDEX territories_crew ON territories (owner_crew_id);
CREATE INDEX territories_cell ON territories (h3_cell);

-- Every change of hands, so a voided activity can be rolled back exactly.
CREATE TABLE territory_events (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    territory_id    BIGINT      NOT NULL REFERENCES territories (id),
    activity_id     BIGINT      REFERENCES activities (id),
    kind            TEXT        NOT NULL
                    CHECK (kind IN ('claim', 'capture', 'weaken', 'reinforce', 'freeze', 'unfreeze', 'reset', 'rollback', 'admin_guard')),
    prev_owner_id   BIGINT,
    new_owner_id    BIGINT,
    prev_guard      INT,
    new_guard       INT,
    prev_geom       geometry(MultiPolygon, 4326),
    actor_admin_id  BIGINT,                -- set for admin actions (审计)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX territory_events_activity ON territory_events (activity_id);

CREATE TABLE territory_buildings (
    territory_id    BIGINT      NOT NULL REFERENCES territories (id) ON DELETE CASCADE,
    slot            SMALLINT    NOT NULL CHECK (slot BETWEEN 0 AND 15),
    building        TEXT        NOT NULL,
    built_by        BIGINT      NOT NULL REFERENCES users (id),
    built_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (territory_id, slot)
);

CREATE TABLE territory_stationed (
    territory_id    BIGINT      NOT NULL REFERENCES territories (id) ON DELETE CASCADE,
    role            TEXT        NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES users (id),
    PRIMARY KEY (territory_id, role, user_id)
);

-- Collection (图鉴): roles, blueprints, eggs/companions, monsters, medals.
CREATE TABLE codex_items (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind            TEXT        NOT NULL CHECK (kind IN ('role', 'blueprint', 'egg', 'companion', 'monster', 'medal')),
    item            TEXT        NOT NULL,
    progress        DOUBLE PRECISION NOT NULL DEFAULT 0,  -- e.g. km run towards hatching
    obtained_at     TIMESTAMPTZ,
    PRIMARY KEY (user_id, kind, item)
);

-- Versioned gameplay config (玩法配置 · 发布与回滚).
CREATE TABLE gameplay_configs (
    version         TEXT        PRIMARY KEY,
    body            JSONB       NOT NULL,
    rollout_pct     SMALLINT    NOT NULL DEFAULT 0 CHECK (rollout_pct BETWEEN 0 AND 100),
    note            TEXT,
    published_by    BIGINT,
    published_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
