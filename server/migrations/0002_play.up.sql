-- V2 batch 1: city monsters, chests, defense, seasons, league, campaigns,
-- orienteering routes, companion growth, crew relays, achievement counters.

CREATE TABLE bosses (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind            TEXT        NOT NULL,
    name            TEXT        NOT NULL,
    level           INT         NOT NULL DEFAULT 1,
    location_name   TEXT        NOT NULL DEFAULT '',
    center          geometry(Point, 4326) NOT NULL,
    radius_m        DOUBLE PRECISION NOT NULL,
    hp_max          INT         NOT NULL CHECK (hp_max > 0),
    hp              INT         NOT NULL CHECK (hp >= 0),
    status          TEXT        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'defeated', 'expired')),
    drops           JSONB       NOT NULL,           -- drop table snapshot at spawn (公示用)
    spawned_by      BIGINT,                         -- admin id, NULL = system
    spawned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    ended_at        TIMESTAMPTZ
);
CREATE INDEX bosses_active ON bosses USING GIST (center) WHERE status = 'active';
CREATE INDEX bosses_status ON bosses (status, spawned_at DESC);

CREATE TABLE boss_hits (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    boss_id         BIGINT      NOT NULL REFERENCES bosses (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    crew_id         BIGINT,
    source          TEXT        NOT NULL CHECK (source IN ('strike', 'activity')),
    activity_id     BIGINT      REFERENCES activities (id) ON DELETE SET NULL,
    damage          INT         NOT NULL,
    energy_spent    INT         NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX boss_hits_boss ON boss_hits (boss_id, user_id);
CREATE INDEX boss_hits_user ON boss_hits (user_id, created_at DESC);

CREATE TABLE boss_engagements (
    boss_id         BIGINT      NOT NULL REFERENCES bosses (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    until           TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (boss_id, user_id)
);

CREATE TABLE boss_rewards (
    boss_id         BIGINT      NOT NULL REFERENCES bosses (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    rank            INT         NOT NULL,
    damage          INT         NOT NULL,
    items           JSONB       NOT NULL,           -- [{item, kind, name, converted_energy}]
    energy          INT         NOT NULL DEFAULT 0, -- total energy granted (drops + refund)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (boss_id, user_id)
);

CREATE TABLE user_monsters (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind            TEXT        NOT NULL,
    strikes         INT         NOT NULL DEFAULT 0,
    defeats         INT         NOT NULL DEFAULT 0,
    best_rank       INT,
    PRIMARY KEY (user_id, kind)
);

CREATE TABLE chests (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    center          geometry(Point, 4326) NOT NULL,
    radius_m        DOUBLE PRECISION NOT NULL,
    energy_min      INT         NOT NULL,
    energy_max      INT         NOT NULL,
    source          TEXT        NOT NULL DEFAULT 'system',  -- system | admin
    placed_by       BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    removed_at      TIMESTAMPTZ
);
CREATE INDEX chests_center ON chests USING GIST (center);
CREATE INDEX chests_expires ON chests (expires_at);

CREATE TABLE chest_opens (
    chest_id        BIGINT      NOT NULL REFERENCES chests (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    energy          INT         NOT NULL,
    bonus           BOOLEAN     NOT NULL DEFAULT false,
    activity_id     BIGINT,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (chest_id, user_id)
);

-- 守地挑战: open after an attack, closed by the owner's run or the deadline.
CREATE TABLE territory_defenses (
    territory_id    BIGINT      PRIMARY KEY REFERENCES territories (id) ON DELETE CASCADE,
    attacker_id     BIGINT,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    deadline        TIMESTAMPTZ NOT NULL
);

-- Achievement counters: defends, boss_defeats, chests, routes, loops_single (max).
CREATE TABLE user_stats (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    key             TEXT        NOT NULL,
    value           DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, key)
);

CREATE TABLE seasons (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL CHECK (ends_at > starts_at),
    settled_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    EXCLUDE USING gist (tstzrange(starts_at, ends_at) WITH &&)
);

CREATE TABLE season_results (
    season_id       BIGINT      NOT NULL REFERENCES seasons (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    area_m2         DOUBLE PRECISION NOT NULL,
    rank            INT         NOT NULL,
    tier            TEXT        NOT NULL,
    PRIMARY KEY (season_id, user_id)
);

CREATE TABLE task_completions (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    task_key        TEXT        NOT NULL,
    period          DATE        NOT NULL,   -- week start (Monday, Shanghai)
    reward_energy   INT         NOT NULL,
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, task_key, period)
);

CREATE TABLE league_results (
    week_start      DATE        NOT NULL,
    district        TEXT        NOT NULL,
    crew_id         BIGINT      NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    rank            INT         NOT NULL,
    score_m2        DOUBLE PRECISION NOT NULL,
    active_members  INT         NOT NULL,
    PRIMARY KEY (week_start, district, crew_id)
);

CREATE TABLE campaigns (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title           TEXT        NOT NULL,
    type            TEXT        NOT NULL CHECK (type IN ('pace', 'night_run', 'distance')),
    description     TEXT        NOT NULL DEFAULT '',
    rules           JSONB       NOT NULL,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL CHECK (ends_at > starts_at),
    reward_energy   INT         NOT NULL DEFAULT 0,
    reward_medal_name TEXT,
    created_by      BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE campaign_completions (
    campaign_id     BIGINT      NOT NULL REFERENCES campaigns (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    activity_id     BIGINT,
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (campaign_id, user_id)
);

CREATE TABLE routes (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            TEXT        NOT NULL,
    description     TEXT        NOT NULL DEFAULT '',
    checkpoints     JSONB       NOT NULL,   -- [{name, lat, lng, radius_m}]
    bbox            geometry(Polygon, 4326),
    reward_energy   INT         NOT NULL DEFAULT 0,
    starts_at       TIMESTAMPTZ NOT NULL,
    ends_at         TIMESTAMPTZ NOT NULL CHECK (ends_at > starts_at),
    created_by      BIGINT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE route_progress (
    route_id        BIGINT      NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    next_index      INT         NOT NULL DEFAULT 0,
    completed_at    TIMESTAMPTZ,
    PRIMARY KEY (route_id, user_id)
);

CREATE TABLE companion_growth (
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    companion       TEXT        NOT NULL,
    exp             INT         NOT NULL DEFAULT 0,
    meters          DOUBLE PRECISION NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, companion)
);

CREATE TABLE relays (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    crew_id         BIGINT      NOT NULL REFERENCES crews (id) ON DELETE CASCADE,
    legs            INT         NOT NULL CHECK (legs BETWEEN 2 AND 20),
    leg_km          DOUBLE PRECISION NOT NULL CHECK (leg_km > 0),
    status          TEXT        NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'completed', 'expired')),
    started_by      BIGINT      NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    completed_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX relays_one_running ON relays (crew_id) WHERE status = 'running';

CREATE TABLE relay_runs (
    relay_id        BIGINT      NOT NULL REFERENCES relays (id) ON DELETE CASCADE,
    leg             INT         NOT NULL,
    user_id         BIGINT      NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    activity_id     BIGINT,
    distance_m      DOUBLE PRECISION NOT NULL,
    at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (relay_id, leg),
    UNIQUE (relay_id, user_id)
);

ALTER TABLE territory_events DROP CONSTRAINT territory_events_kind_check;
ALTER TABLE territory_events ADD CONSTRAINT territory_events_kind_check CHECK (kind IN (
    'claim', 'capture', 'capture_whole', 'cut', 'weaken', 'build', 'reinforce',
    'freeze', 'unfreeze', 'reset', 'rollback', 'admin_guard', 'owner_deleted'));
