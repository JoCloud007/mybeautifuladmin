"""Ordonnanceur de maintenance.

Chaque planification décrit *quoi* faire (action), *sur qui* (hôte, étiquette,
type ou tout le parc) et *quand* (expression cron). Une boucle réveille les
planifications échues et exécute l'action via le même chemin que l'UI, ce qui
garantit une traçabilité identique dans le journal des actions.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import os
import zoneinfo

from croniter import croniter

from .bus import bus
from .db import execute, fetch_all, fetch_one

log = logging.getLogger("mba.scheduler")

TICK = 30.0  # fréquence de réveil de la boucle

ACTIONS = {
    "upgrade": "Mise à jour des paquets",
    "reboot": "Redémarrage",
    "shutdown": "Extinction",
    "service": "Redémarrage d'un service",
    "container": "Action sur un conteneur",
    "prune": "Purge Docker",
    "command": "Commande personnalisée",
}

# Actions qui n'ont de sens que sur une machine joignable en SSH.
SSH_ACTIONS = {"upgrade", "service", "command", "prune", "container"}


def timezone() -> zoneinfo.ZoneInfo:
    try:
        return zoneinfo.ZoneInfo(os.getenv("TZ", "UTC"))
    except zoneinfo.ZoneInfoNotFoundError:
        return zoneinfo.ZoneInfo("UTC")


def next_occurrence(cron: str, after: dt.datetime | None = None) -> dt.datetime:
    """Prochaine échéance d'une expression cron, dans le fuseau configuré."""
    tz = timezone()
    base = (after or dt.datetime.now(dt.timezone.utc)).astimezone(tz)
    return croniter(cron, base).get_next(dt.datetime).astimezone(dt.timezone.utc)


def validate_cron(cron: str) -> None:
    if not croniter.is_valid(cron):
        raise ValueError(f"Expression cron invalide : « {cron} »")


# ------------------------------------------------------------------- cibles
def target_values(schedule: dict) -> list[str]:
    """Cibles d'une planification, toujours sous forme de liste.

    La colonne `target_value` est un TEXT historique : les cibles multiples y
    sont stockées séparées par des virgules. Les identifiants d'hôtes, les
    étiquettes et les types ne contiennent pas de virgule, le séparateur est
    donc sans ambiguïté.
    """
    raw = schedule.get("target_value")
    if raw is None:
        return []
    values = raw if isinstance(raw, (list, tuple)) else str(raw).split(",")
    seen, out = set(), []
    for value in values:
        cleaned = str(value).strip()
        if cleaned and cleaned not in seen:
            seen.add(cleaned)
            out.append(cleaned)
    return out


async def resolve_targets(schedule: dict) -> list[dict]:
    kind = schedule["target_kind"]
    values = target_values(schedule)

    if kind == "all":
        return await fetch_all("SELECT * FROM hosts WHERE enabled ORDER BY name")
    if not values:
        return []
    if kind == "host":
        ids = [int(v) for v in values if v.lstrip("-").isdigit()]
        if not ids:
            return []
        return await fetch_all(
            "SELECT * FROM hosts WHERE enabled AND id = ANY(CAST(:ids AS integer[])) ORDER BY name",
            {"ids": ids},
        )
    if kind == "tag":
        # `&&` = intersection : l'hôte porte au moins une des étiquettes visées.
        return await fetch_all(
            "SELECT * FROM hosts WHERE enabled AND tags && CAST(:tags AS text[]) ORDER BY name",
            {"tags": values},
        )
    if kind == "kind":
        return await fetch_all(
            "SELECT * FROM hosts WHERE enabled AND kind = ANY(CAST(:kinds AS text[])) ORDER BY name",
            {"kinds": values},
        )
    return []


# ---------------------------------------------------------------- exécution
async def execute_schedule(schedule: dict, username: str = "planificateur") -> dict:
    """Exécute une planification sur toutes ses cibles et renvoie un résumé."""
    from . import actions as act  # import tardif : actions importe poller

    hosts = await resolve_targets(schedule)
    action = schedule["action"]
    params = schedule.get("params") or {}
    results: list[str] = []
    failures = 0

    if not hosts:
        return {"status": "failed", "output": "Aucune cible ne correspond à cette planification."}

    for host in hosts:
        label = host["name"]
        try:
            if action in SSH_ACTIONS and host["kind"] not in ("linux", "docker"):
                results.append(f"⤳ {label} : ignoré (action réservée aux hôtes Linux)")
                continue

            if action == "upgrade":
                out = await act.upgrade_host(host, username)
                results.append(f"✔ {label} : mise à jour {out['status']}")
            elif action in ("reboot", "shutdown"):
                if host["kind"] == "synology":
                    await act.syno_action(host, action, username)
                elif host["kind"] == "proxmox":
                    nodes = (host.get("meta") or {}).get("nodes") or []
                    if not nodes:
                        raise RuntimeError("nœud Proxmox inconnu")
                    await act.pve_node_action(host, nodes[0], action, username)
                else:
                    await act.power_action(host, action, username)
                results.append(f"✔ {label} : {action} demandé")
            elif action == "service":
                out = await act.service_action(host, params.get("service", ""),
                                               params.get("mode", "restart"), username)
                results.append(f"✔ {label} : {params.get('service')} → {out['status']}")
            elif action == "container":
                out = await act.container_action(host, params.get("container", ""),
                                                 params.get("mode", "restart"), username)
                results.append(f"✔ {label} : conteneur {params.get('container')} ok")
            elif action == "prune":
                from .collectors import docker as docker_col

                reclaimed = 0
                for target in params.get("targets") or ["containers", "images", "build_cache"]:
                    outcome = await docker_col.prune(host, target)
                    reclaimed += outcome.get("reclaimed") or 0
                results.append(f"✔ {label} : purge, {reclaimed / 1e9:.2f} Go récupérés")
            elif action == "command":
                out = await act.run_command(host, params.get("command", "true"), username,
                                            timeout=params.get("timeout", 600))
                results.append(f"✔ {label} : sortie {out['exit_code']}")
            else:
                raise RuntimeError(f"action inconnue « {action} »")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            results.append(f"✖ {label} : {str(exc)[:200]}")

    status = "success" if failures == 0 else ("partial" if failures < len(hosts) else "failed")
    return {"status": status, "output": "\n".join(results), "hosts": len(hosts), "failures": failures}


async def run_now(schedule_id: int, username: str) -> dict:
    schedule = await fetch_one("SELECT * FROM schedules WHERE id = :id", {"id": schedule_id})
    if not schedule:
        raise ValueError("Planification introuvable")
    return await _run_and_record(schedule, username)


async def _run_and_record(schedule: dict, username: str) -> dict:
    await execute("UPDATE schedules SET running = true WHERE id = :id", {"id": schedule["id"]})
    bus.publish("schedule", {"id": schedule["id"], "name": schedule["name"], "state": "running"})
    started = dt.datetime.now(dt.timezone.utc)
    try:
        outcome = await execute_schedule(schedule, username)
    except Exception as exc:  # noqa: BLE001
        outcome = {"status": "failed", "output": f"Erreur interne : {exc}"}

    await execute(
        """UPDATE schedules
           SET running = false, last_run = :run, last_status = :status, last_output = :output,
               next_run = :next
           WHERE id = :id""",
        {"id": schedule["id"], "run": started, "status": outcome["status"],
         "output": (outcome.get("output") or "")[:20000],
         "next": next_occurrence(schedule["cron"])},
    )
    bus.publish("schedule", {"id": schedule["id"], "name": schedule["name"],
                             "state": "done", "status": outcome["status"]})

    from .poller import log_event

    level = {"success": "info", "partial": "warning"}.get(outcome["status"], "critical")
    await log_event(None, level, "scheduler",
                    f"Planification « {schedule['name']} » : {outcome['status']}",
                    {"schedule_id": schedule["id"]})
    log.info("Planification %s → %s", schedule["name"], outcome["status"])
    return outcome


# -------------------------------------------------------------------- boucle
async def run_scheduler() -> None:
    # Les planifications sans échéance (nouvelles, ou API redémarrée) sont amorcées.
    await asyncio.sleep(5)
    try:
        pending = await fetch_all("SELECT id, cron FROM schedules WHERE next_run IS NULL")
        for row in pending:
            await execute("UPDATE schedules SET next_run = :n WHERE id = :id",
                          {"id": row["id"], "n": next_occurrence(row["cron"])})
        # Un arrêt brutal peut laisser un drapeau « running » : on le nettoie.
        await execute("UPDATE schedules SET running = false WHERE running")
    except Exception as exc:  # noqa: BLE001
        log.warning("Amorçage de l'ordonnanceur : %s", exc)

    while True:
        try:
            due = await fetch_all(
                "SELECT * FROM schedules WHERE enabled AND NOT running AND next_run <= now()"
            )
            for schedule in due:
                asyncio.create_task(_run_and_record(schedule, "planificateur"))
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle de l'ordonnanceur : %s", exc)
        await asyncio.sleep(TICK)


def _enumerate(items: list[str], limit: int = 3) -> str:
    if len(items) <= limit:
        return ", ".join(items)
    return ", ".join(items[:limit]) + f" +{len(items) - limit}"


def describe(schedule: dict, hosts: list[dict] | None = None) -> str:
    """Résumé lisible d'une planification, pour les journaux et l'interface.

    `hosts` (cibles déjà résolues) permet de nommer les hôtes plutôt que
    d'afficher leurs identifiants.
    """
    kind = schedule["target_kind"]
    values = target_values(schedule)
    plural = "s" if len(values) > 1 else ""

    if kind == "all":
        target = "tout le parc"
    elif not values:
        target = "aucune cible"
    elif kind == "host":
        names = [h["name"] for h in hosts] if hosts else [f"#{v}" for v in values]
        target = _enumerate(names) or "aucune cible"
    elif kind == "tag":
        target = f"étiquette{plural} " + _enumerate([f"« {v} »" for v in values])
    else:
        target = f"type{plural} " + _enumerate(values)
    return f"{ACTIONS.get(schedule['action'], schedule['action'])} sur {target} ({schedule['cron']})"


def params_json(params: dict | None) -> str:
    return json.dumps(params or {}, default=str)
