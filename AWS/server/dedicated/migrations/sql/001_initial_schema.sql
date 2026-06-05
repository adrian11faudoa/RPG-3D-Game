-- ============================================================================
-- Veilborn — Initial Database Schema
-- Migration: 001_initial_schema.sql
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- EXTENSIONS
-- ────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- For fuzzy name search

-- ────────────────────────────────────────────────────────────────────────────
-- PLAYERS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS players (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username        VARCHAR(24) NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen       TIMESTAMPTZ,
    is_banned       BOOLEAN NOT NULL DEFAULT FALSE,
    ban_reason      TEXT,
    is_admin        BOOLEAN NOT NULL DEFAULT FALSE,

    -- Position
    pos_x           REAL NOT NULL DEFAULT 0,
    pos_y           REAL NOT NULL DEFAULT 70,
    pos_z           REAL NOT NULL DEFAULT 0,
    rotation_y      REAL NOT NULL DEFAULT 0,

    -- Vitals
    hp              REAL NOT NULL DEFAULT 100,
    stamina         REAL NOT NULL DEFAULT 100,
    mana            REAL NOT NULL DEFAULT 50,

    -- Progression
    level           INT NOT NULL DEFAULT 1,
    xp              BIGINT NOT NULL DEFAULT 0,
    stat_points     INT NOT NULL DEFAULT 0,
    skill_points    INT NOT NULL DEFAULT 0,

    -- Stats (JSONB for flexibility)
    base_stats      JSONB NOT NULL DEFAULT '{"strength":5,"dexterity":5,"intelligence":5,"endurance":5,"spirit":5}'::jsonb,
    unlocked_skills JSONB NOT NULL DEFAULT '{}'::jsonb,

    -- Economy
    gold            INT NOT NULL DEFAULT 100,

    -- Play time (seconds)
    total_play_time BIGINT NOT NULL DEFAULT 0,

    -- Metadata
    client_version  VARCHAR(20)
);

CREATE INDEX idx_players_username ON players USING btree(username);
CREATE INDEX idx_players_last_seen ON players USING btree(last_seen DESC);
CREATE INDEX idx_players_level ON players USING btree(level DESC);

-- ────────────────────────────────────────────────────────────────────────────
-- PLAYER INVENTORY
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_inventory (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    slot_index  INT NOT NULL,
    item_id     VARCHAR(64) NOT NULL,
    amount      INT NOT NULL DEFAULT 1,
    rarity      SMALLINT NOT NULL DEFAULT 0,
    quality     VARCHAR(20) NOT NULL DEFAULT 'common',
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (player_id, slot_index)
);

CREATE INDEX idx_inventory_player ON player_inventory(player_id);

-- ────────────────────────────────────────────────────────────────────────────
-- PLAYER EQUIPMENT (separate table for fast lookups)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_equipment (
    player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    slot        SMALLINT NOT NULL,   -- EquipSlot enum value
    item_id     VARCHAR(64) NOT NULL,
    rarity      SMALLINT NOT NULL DEFAULT 0,
    quality     VARCHAR(20) NOT NULL DEFAULT 'common',
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (player_id, slot)
);

-- ────────────────────────────────────────────────────────────────────────────
-- PLAYER REPUTATION
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_reputation (
    player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    faction_id  VARCHAR(64) NOT NULL,
    reputation  INT NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, faction_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- QUESTS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS player_quests (
    player_id           UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    quest_id            VARCHAR(64) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'active',  -- active, completed, failed
    current_stage       INT NOT NULL DEFAULT 0,
    started_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ,
    objective_progress  JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (player_id, quest_id)
);

CREATE INDEX idx_quests_player_status ON player_quests(player_id, status);

-- ────────────────────────────────────────────────────────────────────────────
-- WORLD STATE
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS world_state (
    key     VARCHAR(128) PRIMARY KEY,
    value   TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Insert defaults
INSERT INTO world_state (key, value) VALUES
    ('world_time',      '480'),
    ('world_day',       '1'),
    ('current_weather', 'CLEAR')
ON CONFLICT (key) DO NOTHING;

-- ────────────────────────────────────────────────────────────────────────────
-- KILLED BOSSES (server-wide, prevents re-spawning same boss)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS killed_bosses (
    boss_id         VARCHAR(64) NOT NULL,
    killed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    killer_id       UUID REFERENCES players(id),
    respawn_at      TIMESTAMPTZ,
    PRIMARY KEY (boss_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- GUILDS
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS guilds (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        VARCHAR(32) NOT NULL UNIQUE,
    tag         VARCHAR(6) NOT NULL UNIQUE,
    leader_id   UUID NOT NULL REFERENCES players(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    description TEXT,
    gold        INT NOT NULL DEFAULT 0,
    emblem      JSONB
);

CREATE TABLE IF NOT EXISTS guild_members (
    guild_id    UUID NOT NULL REFERENCES guilds(id) ON DELETE CASCADE,
    player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    rank        VARCHAR(20) NOT NULL DEFAULT 'member',
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (guild_id, player_id)
);

-- ────────────────────────────────────────────────────────────────────────────
-- SERVER EVENTS & AUDIT LOG
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS server_events (
    id          BIGSERIAL PRIMARY KEY,
    event_type  VARCHAR(64) NOT NULL,
    player_id   UUID REFERENCES players(id),
    data        JSONB NOT NULL DEFAULT '{}'::jsonb,
    server_id   VARCHAR(64),
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_type ON server_events(event_type, occurred_at DESC);
CREATE INDEX idx_events_player ON server_events(player_id, occurred_at DESC);

-- ────────────────────────────────────────────────────────────────────────────
-- LEADERBOARDS (denormalized for fast reads)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS leaderboard_pvp (
    player_id   UUID PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    username    VARCHAR(24) NOT NULL,
    kills       INT NOT NULL DEFAULT 0,
    deaths      INT NOT NULL DEFAULT 0,
    ratio       REAL GENERATED ALWAYS AS (
        CASE WHEN deaths = 0 THEN kills::real ELSE kills::real / deaths END
    ) STORED,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS leaderboard_wealth (
    player_id   UUID PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    username    VARCHAR(24) NOT NULL,
    gold        INT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ────────────────────────────────────────────────────────────────────────────
-- SESSIONS (active connections)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS active_sessions (
    session_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    server_id   VARCHAR(64) NOT NULL,
    peer_id     INT NOT NULL,
    started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_ping   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (player_id)   -- One session per player
);

-- Auto-expire stale sessions (run periodically)
CREATE OR REPLACE FUNCTION cleanup_stale_sessions()
RETURNS void AS $$
BEGIN
    DELETE FROM active_sessions
    WHERE last_ping < NOW() - INTERVAL '2 minutes';
END;
$$ LANGUAGE plpgsql;

-- ────────────────────────────────────────────────────────────────────────────
-- USEFUL VIEWS
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_online_players AS
SELECT
    p.username,
    p.level,
    p.pos_x,
    p.pos_y,
    p.pos_z,
    s.server_id,
    s.started_at AS session_started,
    s.last_ping
FROM players p
JOIN active_sessions s ON s.player_id = p.id
WHERE s.last_ping > NOW() - INTERVAL '2 minutes';

CREATE OR REPLACE VIEW v_leaderboard_level AS
SELECT
    ROW_NUMBER() OVER (ORDER BY level DESC, xp DESC) AS rank,
    username,
    level,
    xp,
    last_seen
FROM players
WHERE is_banned = FALSE
ORDER BY level DESC, xp DESC
LIMIT 100;
