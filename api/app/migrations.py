"""Migrations idempotentes appliquées au démarrage.

db/init/ ne s'exécute que sur un volume vierge : ces instructions couvrent les
installations déjà en place. Chaque énoncé doit pouvoir être rejoué sans effet
de bord.
"""
from __future__ import annotations

import logging

from .db import execute

log = logging.getLogger("mba.migrations")

STATEMENTS: list[str] = [
    # ---------------------------------------------------------- inventaire
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS category TEXT",
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS location TEXT",
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS notes TEXT",
    "CREATE INDEX IF NOT EXISTS idx_hosts_tags ON hosts USING GIN (tags)",
    "CREATE INDEX IF NOT EXISTS idx_hosts_category ON hosts (category)",

    # ------------------------------------------------------- docker compose
    "ALTER TABLE containers ADD COLUMN IF NOT EXISTS labels JSONB NOT NULL DEFAULT '{}'::jsonb",
    "ALTER TABLE containers ADD COLUMN IF NOT EXISTS project TEXT",
    "ALTER TABLE containers ADD COLUMN IF NOT EXISTS service TEXT",
    "CREATE INDEX IF NOT EXISTS idx_containers_project ON containers (project)",

    # ------------------------------------------------------------ découverte
    "ALTER TABLE discovery_results ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'network'",
    "ALTER TABLE discovery_results ADD COLUMN IF NOT EXISTS meta JSONB NOT NULL DEFAULT '{}'::jsonb",

    # ----------------------------------------------------------- ordonnanceur
    """
    CREATE TABLE IF NOT EXISTS schedules (
        id           SERIAL PRIMARY KEY,
        name         TEXT NOT NULL,
        action       TEXT NOT NULL,          -- upgrade | reboot | shutdown | service | container | prune | command
        target_kind  TEXT NOT NULL DEFAULT 'host',  -- host | tag | kind | all
        target_value TEXT,                   -- id d'hôte, étiquette, ou type
        params       JSONB NOT NULL DEFAULT '{}'::jsonb,
        cron         TEXT NOT NULL,
        enabled      BOOLEAN NOT NULL DEFAULT true,
        next_run     TIMESTAMPTZ,
        last_run     TIMESTAMPTZ,
        last_status  TEXT,
        last_output  TEXT,
        running      BOOLEAN NOT NULL DEFAULT false,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_schedules_next ON schedules (enabled, next_run)",
    "ALTER TABLE action_logs ADD COLUMN IF NOT EXISTS schedule_id INTEGER",

    # ------------------------------------------------------------- Tailscale
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS tailscale_id TEXT",
    "CREATE INDEX IF NOT EXISTS idx_hosts_tailscale ON hosts (tailscale_id)",

    # ------------------------------------------- fiche technique éditable
    # Saisie manuelle qui prime sur le relevé automatique (champ par champ).
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS overrides JSONB NOT NULL DEFAULT '{}'::jsonb",

    # ----------------------------------------------------------- sécurité
    """
    CREATE TABLE IF NOT EXISTS security_findings (
        id          SERIAL PRIMARY KEY,
        host_id     INTEGER REFERENCES hosts(id) ON DELETE CASCADE,
        service_id  INTEGER REFERENCES services(id) ON DELETE CASCADE,
        code        TEXT NOT NULL,             -- identifiant stable du contrôle
        severity    TEXT NOT NULL,             -- critical | high | medium | low | info
        title       TEXT NOT NULL,
        detail      TEXT,
        remediation TEXT,
        data        JSONB NOT NULL DEFAULT '{}'::jsonb,
        muted       BOOLEAN NOT NULL DEFAULT false,
        first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
        last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
        resolved_at TIMESTAMPTZ
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_findings_unique "
    "ON security_findings (coalesce(host_id, 0), coalesce(service_id, 0), code)",
    "CREATE INDEX IF NOT EXISTS idx_findings_open ON security_findings (resolved_at, severity)",
    "ALTER TABLE services ADD COLUMN IF NOT EXISTS ssl_issuer TEXT",
    "ALTER TABLE services ADD COLUMN IF NOT EXISTS ssl_checked TIMESTAMPTZ",

    # --------------------------------------------------------------- IPMI
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS bmc_address TEXT",
    "ALTER TABLE hosts ADD COLUMN IF NOT EXISTS bmc_credential_id INTEGER "
    "REFERENCES credentials(id) ON DELETE SET NULL",

    # ------------------------------------------------------------ agents IA
    """
    CREATE TABLE IF NOT EXISTS agents (
        id           SERIAL PRIMARY KEY,
        name         TEXT NOT NULL,
        description  TEXT,
        role         TEXT NOT NULL DEFAULT 'custom',
        endpoint_id  INTEGER REFERENCES ai_endpoints(id) ON DELETE SET NULL,
        model        TEXT NOT NULL,
        system_prompt TEXT,
        mode         TEXT NOT NULL DEFAULT 'observe',   -- observe | suggest | auto
        scope_kind   TEXT NOT NULL DEFAULT 'all',       -- all | tag | kind | host
        scope_value  TEXT,
        allowed_actions TEXT[] NOT NULL DEFAULT '{}',
        max_actions  INTEGER NOT NULL DEFAULT 3,
        cron         TEXT,
        enabled      BOOLEAN NOT NULL DEFAULT true,
        running      BOOLEAN NOT NULL DEFAULT false,
        next_run     TIMESTAMPTZ,
        last_run     TIMESTAMPTZ,
        last_status  TEXT,
        created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_agents_next ON agents (enabled, next_run)",
    """
    CREATE TABLE IF NOT EXISTS agent_runs (
        id          SERIAL PRIMARY KEY,
        agent_id    INTEGER REFERENCES agents(id) ON DELETE CASCADE,
        trigger     TEXT NOT NULL DEFAULT 'manual',
        status      TEXT NOT NULL DEFAULT 'running',
        summary     TEXT,
        analysis    TEXT,
        context     JSONB NOT NULL DEFAULT '{}'::jsonb,
        error       TEXT,
        duration_s  DOUBLE PRECISION,
        started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        ended_at    TIMESTAMPTZ
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_agent_runs ON agent_runs (agent_id, started_at DESC)",
    """
    CREATE TABLE IF NOT EXISTS agent_proposals (
        id          SERIAL PRIMARY KEY,
        run_id      INTEGER REFERENCES agent_runs(id) ON DELETE CASCADE,
        agent_id    INTEGER REFERENCES agents(id) ON DELETE CASCADE,
        action      TEXT NOT NULL,
        host_id     INTEGER REFERENCES hosts(id) ON DELETE CASCADE,
        params      JSONB NOT NULL DEFAULT '{}'::jsonb,
        reason      TEXT,
        severity    TEXT NOT NULL DEFAULT 'medium',
        state       TEXT NOT NULL DEFAULT 'pending',
        result      TEXT,
        decided_by  TEXT,
        created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
        decided_at  TIMESTAMPTZ
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_proposals_state ON agent_proposals (state, created_at DESC)",

    # -------------------------------------------------- auto-remédiation
    """
    CREATE TABLE IF NOT EXISTS remediation_rules (
        id               SERIAL PRIMARY KEY,
        name             TEXT NOT NULL,
        description      TEXT,
        trigger          TEXT NOT NULL,
        action           TEXT NOT NULL,
        params           JSONB NOT NULL DEFAULT '{}'::jsonb,
        scope_kind       TEXT NOT NULL DEFAULT 'all',
        scope_value      TEXT,
        confirm_seconds  INTEGER NOT NULL DEFAULT 300,
        cooldown_seconds INTEGER NOT NULL DEFAULT 1800,
        max_per_day      INTEGER NOT NULL DEFAULT 3,
        allow_destructive BOOLEAN NOT NULL DEFAULT false,
        enabled          BOOLEAN NOT NULL DEFAULT true,
        last_run         TIMESTAMPTZ,
        last_status      TEXT,
        created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS remediation_runs (
        id         SERIAL PRIMARY KEY,
        rule_id    INTEGER REFERENCES remediation_rules(id) ON DELETE CASCADE,
        host_id    INTEGER REFERENCES hosts(id) ON DELETE SET NULL,
        trigger    TEXT,
        status     TEXT NOT NULL DEFAULT 'running',
        detail     TEXT,
        started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        ended_at   TIMESTAMPTZ
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_remediation_runs ON remediation_runs (rule_id, started_at DESC)",

    # ------------------------------------------------------- cloud public
    # Un compte = un projet chez un fournisseur. Les ressources sont volontairement
    # génériques (bucket, instance, volume…) pour accueillir autre chose que du
    # stockage objet sans nouvelle table.
    """
    CREATE TABLE IF NOT EXISTS cloud_accounts (
        id            SERIAL PRIMARY KEY,
        name          TEXT NOT NULL,
        provider      TEXT NOT NULL DEFAULT 'ovh',
        endpoint      TEXT NOT NULL DEFAULT 'ovh-eu',   -- ovh-eu | ovh-ca | ovh-us
        project_id    TEXT,                             -- identifiant du projet Public Cloud
        credential_id INTEGER REFERENCES credentials(id) ON DELETE SET NULL,
        enabled       BOOLEAN NOT NULL DEFAULT true,
        sync_minutes  INTEGER NOT NULL DEFAULT 30,
        status        TEXT NOT NULL DEFAULT 'unknown',  -- online | offline | unknown
        last_error    TEXT,
        last_sync     TIMESTAMPTZ,
        meta          JSONB NOT NULL DEFAULT '{}'::jsonb,
        created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (provider, project_id)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS cloud_resources (
        id          SERIAL PRIMARY KEY,
        account_id  INTEGER NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
        kind        TEXT NOT NULL,            -- bucket | container | instance | volume
        ext_id      TEXT NOT NULL,
        name        TEXT NOT NULL,
        region      TEXT,
        status      TEXT,
        size_bytes  DOUBLE PRECISION,
        objects     DOUBLE PRECISION,
        price_month DOUBLE PRECISION,
        quota_bytes DOUBLE PRECISION,         -- seuil de surveillance, saisi à la main
        host_id     INTEGER REFERENCES hosts(id) ON DELETE SET NULL,  -- PBS adossé au bucket
        link_ref    TEXT,                     -- datastore PBS correspondant
        notes       TEXT,
        meta        JSONB NOT NULL DEFAULT '{}'::jsonb,
        first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
        last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (account_id, ext_id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_cloud_resources_kind ON cloud_resources (kind, name)",
    """
    CREATE TABLE IF NOT EXISTS cloud_usage (
        time        TIMESTAMPTZ NOT NULL,
        account_id  INTEGER NOT NULL REFERENCES cloud_accounts(id) ON DELETE CASCADE,
        resource_id INTEGER REFERENCES cloud_resources(id) ON DELETE CASCADE,
        metric      TEXT NOT NULL,            -- storage.bytes | storage.objects | cost.month…
        value       DOUBLE PRECISION NOT NULL
    )
    """,
    "SELECT create_hypertable('cloud_usage', 'time', if_not_exists => TRUE, "
    "chunk_time_interval => INTERVAL '30 days')",
    "CREATE INDEX IF NOT EXISTS idx_cloud_usage_resource ON cloud_usage (resource_id, metric, time DESC)",
    "CREATE INDEX IF NOT EXISTS idx_cloud_usage_account ON cloud_usage (account_id, metric, time DESC)",
    # Deux ans : la volumétrie d'un stockage objet se lit sur des saisons, pas
    # sur des minutes, et un point toutes les demi-heures pèse peu.
    "SELECT add_retention_policy('cloud_usage', INTERVAL '730 days', if_not_exists => TRUE)",

    # ------------------------------------------------------- endpoints IA
    # Une API compatible OpenAI (vLLM, passerelle) peut demander une clé :
    # elle est chiffrée par le coffre, comme les identifiants SSH ou SMTP.
    "ALTER TABLE ai_endpoints ADD COLUMN IF NOT EXISTS api_key_enc TEXT",

    # --------------------------------------------- tableaux de bord perso
    """
    CREATE TABLE IF NOT EXISTS dashboards (
        id         SERIAL PRIMARY KEY,
        name       TEXT NOT NULL,
        layout     JSONB NOT NULL DEFAULT '[]'::jsonb,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
    """,
]


async def apply() -> None:
    for statement in STATEMENTS:
        try:
            await execute(statement)
        except Exception as exc:  # noqa: BLE001
            log.warning("Migration ignorée (%s…) : %s", statement.strip()[:60], exc)
    log.info("Schéma à jour (%d instructions vérifiées)", len(STATEMENTS))
