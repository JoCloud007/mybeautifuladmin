"""Auto-remédiation : corriger sans attendre une intervention humaine.

Une règle observe une condition (machine injoignable, alerte, constat de
sécurité, service en panne), attend qu'elle persiste, puis applique une action —
soit directement, soit en déléguant l'analyse à un agent IA.

Trois garde-fous, tous vérifiés côté serveur :

* un **délai de confirmation** avant d'agir, pour ne pas réagir à un faux positif ;
* un **temps de repos** après chaque exécution, pour ne pas boucler ;
* un **quota journalier** par règle, pour qu'une panne persistante ne déclenche
  pas une remédiation en rafale.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
from typing import Any

from . import notify
from .bus import bus
from .db import execute, fetch_all, fetch_one

log = logging.getLogger("mba.remediation")

TICK = 60.0

# Ce qu'une règle peut observer.
TRIGGERS: dict[str, dict[str, str]] = {
    "host_offline": {
        "label": "Machine injoignable",
        "help": "La collecte échoue depuis le délai de confirmation.",
    },
    "service_down": {
        "label": "Service web en panne",
        "help": "Une sonde HTTP échoue de façon répétée.",
    },
    "alert_firing": {
        "label": "Alerte de seuil active",
        "help": "CPU, mémoire ou disque au-delà du seuil configuré.",
    },
    "security_finding": {
        "label": "Constat de sécurité",
        "help": "Un contrôle remonte un problème — filtrable par code.",
    },
    "container_stopped": {
        "label": "Conteneur arrêté",
        "help": "Un conteneur qui devrait tourner est à l'arrêt.",
    },
    "disk_pressure": {
        "label": "Disque presque plein",
        "help": "Occupation au-delà du seuil sur au moins un système de fichiers.",
    },
}

# Ce qu'une règle peut faire. `destructive` exige une validation, jamais d'auto.
ACTIONS: dict[str, dict[str, Any]] = {
    "restart_service": {"label": "Redémarrer le service", "params": ["service"], "destructive": False},
    "restart_container": {"label": "Redémarrer le conteneur", "params": [], "destructive": False},
    "start_container": {"label": "Démarrer le conteneur", "params": [], "destructive": False},
    "upgrade_host": {"label": "Mettre à jour les paquets", "params": [], "destructive": False},
    "prune_docker": {"label": "Purger conteneurs arrêtés et cache", "params": [], "destructive": False},
    "reboot_host": {"label": "Redémarrer la machine", "params": [], "destructive": True},
    "run_agent": {"label": "Confier le diagnostic à un agent IA", "params": ["agent_id"],
                  "destructive": False},
    "notify_only": {"label": "Notifier seulement", "params": [], "destructive": False},
}


class RemediationError(RuntimeError):
    pass


# ------------------------------------------------------------------ détection
async def _matching_targets(rule: dict) -> list[dict]:
    """Cibles qui satisfont la condition depuis assez longtemps."""
    delay = int(rule.get("confirm_seconds") or 300)
    scope_kind, scope_value = rule["scope_kind"], rule.get("scope_value")
    params: dict[str, Any] = {"delay": delay}

    scope_sql = ""
    if scope_kind == "host":
        scope_sql = " AND h.id = :scope"
        params["scope"] = int(scope_value) if scope_value else -1
    elif scope_kind == "tag":
        scope_sql = " AND :scope = ANY(h.tags)"
        params["scope"] = scope_value
    elif scope_kind == "kind":
        scope_sql = " AND h.kind = :scope"
        params["scope"] = scope_value

    trigger = rule["trigger"]
    if trigger == "host_offline":
        return await fetch_all(
            "SELECT h.* FROM hosts h WHERE h.enabled AND h.status = 'offline' "
            "AND h.last_seen < now() - make_interval(secs => :delay)" + scope_sql,
            params,
        )

    if trigger == "service_down":
        rows = await fetch_all(
            "SELECT s.*, h.* , s.id AS service_id, s.name AS service_name "
            "FROM services s LEFT JOIN hosts h ON h.id = s.host_id "
            "WHERE s.enabled AND s.status = 'down' "
            "AND s.last_checked < now() - make_interval(secs => :delay)" + scope_sql,
            params,
        )
        return rows

    if trigger == "alert_firing":
        return await fetch_all(
            "SELECT h.*, a.message AS alert_message, a.severity AS alert_severity "
            "FROM alerts a JOIN hosts h ON h.id = a.host_id "
            "WHERE a.state = 'firing' "
            "AND a.started_at < now() - make_interval(secs => :delay)" + scope_sql,
            params,
        )

    if trigger == "security_finding":
        code = (rule.get("params") or {}).get("code")
        extra = " AND f.code = :code" if code else ""
        if code:
            params["code"] = code
        return await fetch_all(
            "SELECT h.*, f.code AS finding_code, f.title AS finding_title, "
            "f.severity AS finding_severity FROM security_findings f "
            "JOIN hosts h ON h.id = f.host_id "
            "WHERE f.resolved_at IS NULL AND NOT f.muted "
            "AND f.first_seen < now() - make_interval(secs => :delay)"
            + extra + scope_sql,
            params,
        )

    if trigger == "container_stopped":
        name = (rule.get("params") or {}).get("container")
        extra = " AND c.name = :cname" if name else ""
        if name:
            params["cname"] = name
        return await fetch_all(
            "SELECT h.*, c.name AS container_name, c.ext_id AS container_ext "
            "FROM containers c JOIN hosts h ON h.id = c.host_id "
            "WHERE c.kind = 'docker' AND c.state <> 'running' "
            "AND c.updated_at < now() - make_interval(secs => :delay)" + extra + scope_sql,
            params,
        )

    if trigger == "disk_pressure":
        threshold = float((rule.get("params") or {}).get("threshold") or 90)
        params["threshold"] = threshold
        return await fetch_all(
            "SELECT h.*, m.value AS disk_percent FROM hosts h "
            "JOIN LATERAL (SELECT value FROM metrics WHERE host_id = h.id "
            "  AND metric = 'disk.percent' ORDER BY time DESC LIMIT 1) m ON true "
            "WHERE h.enabled AND m.value >= :threshold" + scope_sql,
            params,
        )

    return []


# ------------------------------------------------------------------ exécution
async def _apply(rule: dict, target: dict) -> dict[str, Any]:
    from . import actions as act

    action = rule["action"]
    params = rule.get("params") or {}
    host = {k: target.get(k) for k in
            ("id", "name", "kind", "address", "port", "credential_id", "meta")}

    if action == "notify_only":
        return {"ok": True, "detail": "Notification seule, aucune action appliquée"}

    if action == "run_agent":
        from .agents import run_agent

        agent = await fetch_one("SELECT * FROM agents WHERE id = :id",
                                {"id": int(params.get("agent_id") or 0)})
        if not agent:
            raise RemediationError("Agent introuvable pour cette règle")
        outcome = await run_agent(agent, trigger=f"remédiation:{rule['name']}")
        return {"ok": outcome["status"] != "failed", "detail": outcome.get("summary") or "",
                "agent_run": outcome.get("run_id")}

    if action == "restart_service":
        service = params.get("service") or target.get("service_name")
        if not service:
            raise RemediationError("Nom du service manquant")
        out = await act.service_action(host, service, "restart", f"remédiation:{rule['name']}")
        return {"ok": out["status"] == "success", "detail": out.get("output", "")[:400]}

    if action in ("restart_container", "start_container"):
        container = params.get("container") or target.get("container_ext") or target.get("container_name")
        if not container:
            raise RemediationError("Conteneur non identifié")
        verb = "restart" if action == "restart_container" else "start"
        out = await act.container_action(host, container, verb, f"remédiation:{rule['name']}")
        return {"ok": True, "detail": out.get("output", "")[:400]}

    if action == "upgrade_host":
        out = await act.upgrade_host(host, f"remédiation:{rule['name']}")
        return {"ok": out["status"] == "success", "detail": f"mise à jour {out['status']}"}

    if action == "prune_docker":
        from .collectors.docker import prune

        reclaimed = 0
        for what in ("containers", "build_cache"):
            outcome = await prune(host, what)
            reclaimed += outcome.get("reclaimed") or 0
        return {"ok": True, "detail": f"{reclaimed / 1e9:.2f} Go récupérés"}

    if action == "reboot_host":
        await act.power_action(host, "reboot", f"remédiation:{rule['name']}")
        return {"ok": True, "detail": "redémarrage demandé"}

    raise RemediationError(f"Action inconnue : {action}")


async def run_rule(rule: dict, manual: bool = False) -> dict[str, Any]:
    """Évalue une règle et applique l'action sur chaque cible retenue."""
    spec = ACTIONS.get(rule["action"])
    if not spec:
        raise RemediationError(f"Action inconnue : {rule['action']}")
    # Une action destructive ne part jamais toute seule.
    if spec["destructive"] and not rule.get("allow_destructive"):
        raise RemediationError(
            f"« {spec['label']} » interrompt un service : coche « autoriser les actions "
            "destructives » sur cette règle pour l'utiliser."
        )

    targets = await _matching_targets(rule)
    if not targets:
        return {"matched": 0, "applied": 0, "results": []}

    quota = int(rule.get("max_per_day") or 3)
    today = await fetch_one(
        "SELECT count(*) AS n FROM remediation_runs "
        "WHERE rule_id = :r AND started_at > now() - interval '24 hours'",
        {"r": rule["id"]},
    )
    remaining = quota - ((today or {}).get("n") or 0)
    if remaining <= 0 and not manual:
        log.info("Règle « %s » : quota journalier atteint", rule["name"])
        return {"matched": len(targets), "applied": 0, "results": [],
                "note": "quota journalier atteint"}

    results = []
    for target in targets[:max(1, remaining)]:
        run_id = await execute(
            "INSERT INTO remediation_runs (rule_id, host_id, trigger, status) "
            "VALUES (:r, :h, :t, 'running') RETURNING id",
            {"r": rule["id"], "h": target.get("id"),
             "t": "manuel" if manual else rule["trigger"]},
        )
        try:
            outcome = await _apply(rule, target)
            status = "success" if outcome["ok"] else "failed"
            detail = outcome.get("detail", "")
        except Exception as exc:  # noqa: BLE001
            status, detail = "failed", str(exc)[:800]
            log.warning("Remédiation « %s » sur %s : %s", rule["name"], target.get("name"), exc)

        await execute(
            "UPDATE remediation_runs SET status = :s, detail = :d, ended_at = now() WHERE id = :id",
            {"s": status, "d": detail[:2000], "id": run_id},
        )
        results.append({"host": target.get("name"), "status": status, "detail": detail})

        from .poller import log_event
        await log_event(
            target.get("id"), "warning" if status == "failed" else "info", "remédiation",
            f"« {rule['name']} » sur {target.get('name')} : {status}",
            {"action": rule["action"], "détail": detail[:300]},
        )
        await notify.dispatch(
            "remediation",
            f"Auto-remédiation {status} — {target.get('name')}",
            notify.format_event(target.get("name"), status, f"Règle « {rule['name']} »",
                                {"action": ACTIONS[rule["action"]]["label"], "résultat": detail[:300]}),
            dedupe_key=f"remediation:{rule['id']}:{target.get('id')}",
        )

    await execute(
        "UPDATE remediation_rules SET last_run = now(), last_status = :s WHERE id = :id",
        {"s": results[-1]["status"] if results else "idle", "id": rule["id"]},
    )
    bus.publish("remediation", {"rule": rule["name"], "applied": len(results)})
    return {"matched": len(targets), "applied": len(results), "results": results}


# --------------------------------------------------------------------- boucle
async def run_loop() -> None:
    await asyncio.sleep(75)  # laisse la collecte établir un premier état
    while True:
        try:
            rules = await fetch_all(
                "SELECT * FROM remediation_rules WHERE enabled "
                "AND (last_run IS NULL OR last_run < now() - make_interval(secs => cooldown_seconds))"
            )
            for rule in rules:
                try:
                    await run_rule(rule)
                except RemediationError as exc:
                    log.info("Règle « %s » ignorée : %s", rule["name"], exc)
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle de remédiation : %s", exc)
        await asyncio.sleep(TICK)
