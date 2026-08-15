-- MyBeautifulAdmin -- schéma initial
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------- utilisateurs
CREATE TABLE IF NOT EXISTS users (
    id           SERIAL PRIMARY KEY,
    username     TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role         TEXT NOT NULL DEFAULT 'admin',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- credentials
-- Les secrets sont chiffrés côté API (Fernet) avant insertion.
CREATE TABLE IF NOT EXISTS credentials (
    id         SERIAL PRIMARY KEY,
    name       TEXT UNIQUE NOT NULL,
    kind       TEXT NOT NULL,              -- ssh_password | ssh_key | api_token | basic
    username   TEXT,
    secret_enc TEXT,                       -- mot de passe / clé privée / token (chiffré)
    passphrase_enc TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- hôtes
CREATE TABLE IF NOT EXISTS hosts (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    kind          TEXT NOT NULL,            -- linux | proxmox | synology | docker | generic
    address       TEXT NOT NULL,
    port          INTEGER,
    credential_id INTEGER REFERENCES credentials(id) ON DELETE SET NULL,
    parent_id     INTEGER REFERENCES hosts(id) ON DELETE CASCADE,  -- VM/LXC -> hyperviseur
    tags          TEXT[] NOT NULL DEFAULT '{}',
    enabled       BOOLEAN NOT NULL DEFAULT true,
    status        TEXT NOT NULL DEFAULT 'unknown',  -- online | offline | warning | unknown
    last_seen     TIMESTAMPTZ,
    last_error    TEXT,
    meta          JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (address, kind, port)
);
CREATE INDEX IF NOT EXISTS idx_hosts_kind ON hosts(kind);
CREATE INDEX IF NOT EXISTS idx_hosts_parent ON hosts(parent_id);

-- ---------------------------------------------------------------- métriques
CREATE TABLE IF NOT EXISTS metrics (
    time    TIMESTAMPTZ NOT NULL,
    host_id INTEGER NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    metric  TEXT NOT NULL,                 -- cpu.usage, mem.used, disk.used./, net.rx.eth0 ...
    value   DOUBLE PRECISION NOT NULL
);
SELECT create_hypertable('metrics', 'time', if_not_exists => TRUE, chunk_time_interval => INTERVAL '1 day');
CREATE INDEX IF NOT EXISTS idx_metrics_host_metric_time ON metrics (host_id, metric, time DESC);

-- rétention : 14 jours de points bruts
SELECT add_retention_policy('metrics', INTERVAL '14 days', if_not_exists => TRUE);

-- agrégat continu 1 minute pour les vues longues
CREATE MATERIALIZED VIEW IF NOT EXISTS metrics_1m
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 minute', time) AS bucket,
       host_id, metric,
       avg(value) AS avg_value,
       max(value) AS max_value,
       min(value) AS min_value
FROM metrics
GROUP BY bucket, host_id, metric
WITH NO DATA;

SELECT add_continuous_aggregate_policy('metrics_1m',
    start_offset => INTERVAL '3 hours',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute',
    if_not_exists => TRUE);

-- ---------------------------------------------------------------- conteneurs
CREATE TABLE IF NOT EXISTS containers (
    id         SERIAL PRIMARY KEY,
    host_id    INTEGER NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    ext_id     TEXT NOT NULL,              -- id docker / vmid proxmox
    name       TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'docker',  -- docker | lxc | qemu
    image      TEXT,
    state      TEXT,
    status     TEXT,
    ports      JSONB NOT NULL DEFAULT '[]'::jsonb,
    stats      JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (host_id, ext_id)
);
CREATE INDEX IF NOT EXISTS idx_containers_host ON containers(host_id);

-- ---------------------------------------------------------------- services web
CREATE TABLE IF NOT EXISTS services (
    id           SERIAL PRIMARY KEY,
    name         TEXT NOT NULL,
    url          TEXT NOT NULL,
    host_id      INTEGER REFERENCES hosts(id) ON DELETE SET NULL,
    method       TEXT NOT NULL DEFAULT 'GET',
    expect_status INTEGER NOT NULL DEFAULT 200,
    expect_body  TEXT,
    interval_s   INTEGER NOT NULL DEFAULT 30,
    icon         TEXT,
    group_name   TEXT,
    enabled      BOOLEAN NOT NULL DEFAULT true,
    status       TEXT NOT NULL DEFAULT 'unknown',
    last_latency_ms DOUBLE PRECISION,
    last_checked TIMESTAMPTZ,
    ssl_expires_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS service_checks (
    time       TIMESTAMPTZ NOT NULL,
    service_id INTEGER NOT NULL REFERENCES services(id) ON DELETE CASCADE,
    ok         BOOLEAN NOT NULL,
    status_code INTEGER,
    latency_ms DOUBLE PRECISION,
    error      TEXT
);
SELECT create_hypertable('service_checks', 'time', if_not_exists => TRUE, chunk_time_interval => INTERVAL '7 days');
CREATE INDEX IF NOT EXISTS idx_service_checks ON service_checks (service_id, time DESC);
SELECT add_retention_policy('service_checks', INTERVAL '90 days', if_not_exists => TRUE);

-- ---------------------------------------------------------------- IA
CREATE TABLE IF NOT EXISTS ai_endpoints (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    url        TEXT NOT NULL,              -- http://10.0.0.5:11434
    host_id    INTEGER REFERENCES hosts(id) ON DELETE SET NULL,
    kind       TEXT NOT NULL DEFAULT 'ollama',
    enabled    BOOLEAN NOT NULL DEFAULT true,
    status     TEXT NOT NULL DEFAULT 'unknown',
    meta       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- évènements / actions
CREATE TABLE IF NOT EXISTS events (
    id         BIGSERIAL,
    time       TIMESTAMPTZ NOT NULL DEFAULT now(),
    host_id    INTEGER REFERENCES hosts(id) ON DELETE CASCADE,
    level      TEXT NOT NULL DEFAULT 'info',   -- info | warning | critical
    source     TEXT NOT NULL DEFAULT 'system',
    message    TEXT NOT NULL,
    data       JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (id, time)
);
SELECT create_hypertable('events', 'time', if_not_exists => TRUE, chunk_time_interval => INTERVAL '7 days');
CREATE INDEX IF NOT EXISTS idx_events_time ON events (time DESC);
SELECT add_retention_policy('events', INTERVAL '90 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS action_logs (
    id         SERIAL PRIMARY KEY,
    host_id    INTEGER REFERENCES hosts(id) ON DELETE SET NULL,
    target     TEXT,
    action     TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending',  -- pending | running | success | failed
    output     TEXT,
    username   TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_action_logs_started ON action_logs(started_at DESC);

-- ---------------------------------------------------------------- alertes
CREATE TABLE IF NOT EXISTS alert_rules (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    metric     TEXT NOT NULL,
    host_id    INTEGER REFERENCES hosts(id) ON DELETE CASCADE,  -- NULL = tous
    operator   TEXT NOT NULL DEFAULT '>',
    threshold  DOUBLE PRECISION NOT NULL,
    severity   TEXT NOT NULL DEFAULT 'warning',
    for_s      INTEGER NOT NULL DEFAULT 60,
    enabled    BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS alerts (
    id         SERIAL PRIMARY KEY,
    rule_id    INTEGER REFERENCES alert_rules(id) ON DELETE CASCADE,
    host_id    INTEGER REFERENCES hosts(id) ON DELETE CASCADE,
    severity   TEXT NOT NULL,
    message    TEXT NOT NULL,
    value      DOUBLE PRECISION,
    state      TEXT NOT NULL DEFAULT 'firing',   -- firing | resolved | acked
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_alerts_state ON alerts(state, started_at DESC);

-- ---------------------------------------------------------------- découverte
CREATE TABLE IF NOT EXISTS discovery_results (
    id         SERIAL PRIMARY KEY,
    address    TEXT NOT NULL,
    hostname   TEXT,
    guessed_kind TEXT,
    open_ports INTEGER[] NOT NULL DEFAULT '{}',
    evidence   JSONB NOT NULL DEFAULT '{}'::jsonb,
    adopted    BOOLEAN NOT NULL DEFAULT false,
    ignored    BOOLEAN NOT NULL DEFAULT false,
    seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (address)
);

-- ---------------------------------------------------------------- préférences UI
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value JSONB NOT NULL
);

-- seed alert rules par défaut
INSERT INTO alert_rules (name, metric, operator, threshold, severity, for_s)
SELECT * FROM (VALUES
    ('CPU élevé',      'cpu.usage',  '>', 90.0, 'warning',  120),
    ('RAM élevée',     'mem.percent','>', 92.0, 'warning',  120),
    ('Disque presque plein', 'disk.percent./', '>', 90.0, 'critical', 300)
) AS v(name, metric, operator, threshold, severity, for_s)
WHERE NOT EXISTS (SELECT 1 FROM alert_rules);
