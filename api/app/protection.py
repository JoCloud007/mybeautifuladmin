"""Protection des données : couverture, fraîcheur et risques de sauvegarde.

On agrège trois sources — Proxmox Backup Server, les vzdump d'un PVE et les
tâches Hyper Backup d'un DSM — pour répondre à deux questions : qu'est-ce qui
n'est pas sauvegardé, et quelles sauvegardes ne sont plus fiables.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import logging
from typing import Any

from .bus import bus
from .collectors import pbs as pbs_col
from .collectors import proxmox as pve_col
from .collectors import synology as syno_col
from .db import fetch_all

log = logging.getLogger("mba.protection")

# Au-delà, une sauvegarde n'est plus considérée comme fraîche.
STALE_HOURS = 36
CRITICAL_HOURS = 24 * 7
# Un datastore trop plein fait échouer les sauvegardes suivantes.
STORE_WARN = 80.0
STORE_CRIT = 92.0


def _age_hours(timestamp: Any) -> float | None:
    """Âge en heures d'un epoch (secondes) ou d'une date ISO."""
    if timestamp in (None, "", 0):
        return None
    try:
        if isinstance(timestamp, (int, float)):
            when = dt.datetime.fromtimestamp(float(timestamp), dt.timezone.utc)
        else:
            when = dt.datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
            if when.tzinfo is None:
                when = when.replace(tzinfo=dt.timezone.utc)
    except (ValueError, OSError, OverflowError):
        return None
    return (dt.datetime.now(dt.timezone.utc) - when).total_seconds() / 3600.0


def _freshness(age: float | None) -> str:
    if age is None:
        return "unknown"
    if age > CRITICAL_HOURS:
        return "critical"
    if age > STALE_HOURS:
        return "stale"
    return "fresh"


# ------------------------------------------------------------------ collecte
async def _from_pbs(host: dict) -> dict[str, Any]:
    client = await pbs_col.client_for_host(host)
    try:
        snap = await client.snapshot()
    finally:
        await client.close()

    protected = []
    for group in snap["groups"]:
        age = _age_hours(group.get("last_backup"))
        protected.append({
            "source": "pbs",
            "source_host": host["name"],
            "source_host_id": host["id"],
            "name": f"{group['backup_type']}/{group['backup_id']}",
            "kind": group["backup_type"],
            "ref": str(group["backup_id"]),
            "store": group["store"],
            "count": group["count"],
            "last_backup": group.get("last_backup"),
            "age_hours": age,
            "freshness": _freshness(age),
            "owner": group.get("owner"),
        })
    return {
        "protected": protected,
        "datastores": [{**store, "source_host": host["name"], "source": "pbs"}
                       for store in snap["datastores"]],
        "tasks": [{**task, "source_host": host["name"], "source": "pbs"}
                  for task in snap["tasks"]],
        "notices": [],
    }


async def _from_pve(host: dict) -> dict[str, Any]:
    """Sauvegardes vzdump vues depuis l'hyperviseur."""
    client = await pve_col.client_for_host(host)
    protected: list[dict] = []
    try:
        nodes = (host.get("meta") or {}).get("nodes") or []
        if not nodes:
            fetched = await client.get("/nodes") or []
            nodes = [n["node"] for n in fetched]
        latest: dict[int, dict] = {}
        for node in nodes:
            for backup in await client.backups(node):
                vmid = backup.get("vmid")
                if vmid is None:
                    continue
                current = latest.get(vmid)
                if not current or (backup.get("created") or 0) > (current.get("created") or 0):
                    latest[vmid] = backup
        for vmid, backup in latest.items():
            age = _age_hours(backup.get("created"))
            protected.append({
                "source": "vzdump",
                "source_host": host["name"],
                "source_host_id": host["id"],
                "name": f"vzdump {vmid}",
                "kind": "guest",
                "ref": str(vmid),
                "store": backup.get("storage"),
                "count": 1,
                "size": backup.get("size"),
                "last_backup": backup.get("created"),
                "age_hours": age,
                "freshness": _freshness(age),
            })
    finally:
        await client.close()
    return {"protected": protected, "datastores": [], "tasks": [], "notices": []}


async def _from_synology(host: dict) -> dict[str, Any]:
    client = await syno_col.client_for_host(host)
    try:
        result = await client.hyper_backup()
    finally:
        await client.logout()

    tasks = result.get("tasks") or []
    notices: list[dict[str, Any]] = []
    if result.get("reason"):
        notices.append({
            "host": host["name"],
            "kind": "synology",
            "level": "info" if not result.get("installed") else "warning",
            "message": result["reason"],
        })

    protected, jobs = [], []
    for task in tasks:
        age = _age_hours(task.get("last_backup"))
        ok = str(task.get("last_result", "")).lower() in ("", "success", "done", "0", "normal")
        protected.append({
            "source": "hyperbackup",
            "source_host": host["name"],
            "source_host_id": host["id"],
            "name": task.get("name") or f"tâche {task.get('id')}",
            "kind": "hyperbackup",
            "ref": str(task.get("id")),
            "store": task.get("target"),
            "count": 1,
            "size": task.get("size"),
            "last_backup": task.get("last_backup"),
            "age_hours": age,
            "freshness": _freshness(age),
            "last_result": task.get("last_result"),
            "enabled": task.get("enabled", True),
            "is_c2": bool(task.get("is_c2")),
        })
        jobs.append({
            "source": "c2" if task.get("is_c2") else "hyperbackup",
            "source_host": host["name"],
            "type": "hyperbackup",
            "target": task.get("name"),
            "status": "OK" if ok else str(task.get("last_result")),
            "started": task.get("last_backup"),
            "ended": task.get("last_backup"),
            "schedule": task.get("schedule"),
            "next": task.get("next_backup"),
        })
    # Une tâche vers C2 est une sauvegarde hors site : on la distingue.
    for item in protected:
        if item.pop("is_c2", False):
            item["source"] = "c2"
            item["offsite"] = True

    return {"protected": protected, "datastores": [], "tasks": jobs, "notices": notices}


# ------------------------------------------------------------------ analyse
def _find_gaps(protected: list[dict], guests: list[dict], hosts: list[dict]) -> list[dict]:
    """Ce qui existe mais n'apparaît dans aucune sauvegarde."""
    covered_refs = {p["ref"] for p in protected}
    covered_names = {(p.get("name") or "").lower() for p in protected}
    gaps: list[dict] = []

    for guest in guests:
        vmid = str(guest.get("vmid"))
        if vmid in covered_refs:
            continue
        gaps.append({
            "kind": "guest",
            "name": guest.get("name"),
            "ref": vmid,
            "detail": f"{'VM' if guest.get('type') == 'qemu' else 'Conteneur'} {vmid} sur "
                      f"{guest.get('node')}",
            "host_id": guest.get("host_id"),
            "severity": "high" if guest.get("status") == "running" else "medium",
        })

    for host in hosts:
        # Un NAS se sauvegarde via Hyper Backup, un hyperviseur via ses invités :
        # on ne signale que les machines réellement laissées de côté.
        if host["kind"] not in ("linux", "docker"):
            continue
        # L'hôte Docker interne de MBA n'est pas une machine à sauvegarder.
        if (host.get("meta") or {}).get("builtin"):
            continue
        if host["name"].lower() in covered_names:
            continue
        if any(host["name"].lower() in (p.get("name") or "").lower() for p in protected):
            continue
        gaps.append({
            "kind": "host",
            "name": host["name"],
            "ref": str(host["id"]),
            "detail": f"{host['address']} — aucune sauvegarde identifiée",
            "host_id": host["id"],
            "severity": "medium",
        })
    return gaps


def _find_risks(protected: list[dict], datastores: list[dict], tasks: list[dict]) -> list[dict]:
    risks: list[dict] = []

    for item in protected:
        if item["freshness"] == "critical":
            risks.append({
                "severity": "critical",
                "title": f"{item['name']} : sauvegarde vieille de {item['age_hours'] / 24:.0f} jours",
                "detail": f"Dernière copie sur {item.get('store') or item['source_host']}.",
                "remediation": "Vérifie que la tâche tourne encore, puis relance-la.",
                "target": item["name"],
                "source": item["source"],
            })
        elif item["freshness"] == "stale":
            risks.append({
                "severity": "high",
                "title": f"{item['name']} : pas de sauvegarde depuis {item['age_hours']:.0f} h",
                "detail": f"Seuil de fraîcheur fixé à {STALE_HOURS} h.",
                "remediation": "Contrôle la planification de la tâche.",
                "target": item["name"],
                "source": item["source"],
            })
        elif item["freshness"] == "unknown":
            risks.append({
                "severity": "medium",
                "title": f"{item['name']} : date de dernière sauvegarde inconnue",
                "detail": "La source ne remonte pas d'horodatage exploitable.",
                "remediation": "Ouvre la tâche côté PBS ou DSM pour confirmer son état.",
                "target": item["name"],
                "source": item["source"],
            })

        if item.get("count", 0) == 1 and item["source"] == "pbs":
            risks.append({
                "severity": "medium",
                "title": f"{item['name']} : une seule version conservée",
                "detail": "Sans historique, une corruption propagée n'est plus rattrapable.",
                "remediation": "Augmente la rétention (prune) pour garder plusieurs points.",
                "target": item["name"],
                "source": item["source"],
            })

        if item.get("enabled") is False:
            risks.append({
                "severity": "high",
                "title": f"{item['name']} : tâche désactivée",
                "detail": "La planification existe mais ne s'exécute plus.",
                "remediation": "Réactive la tâche dans Hyper Backup.",
                "target": item["name"],
                "source": item["source"],
            })

    for store in datastores:
        if store["percent"] >= STORE_CRIT:
            risks.append({
                "severity": "critical",
                "title": f"Datastore {store['name']} rempli à {store['percent']:.0f} %",
                "detail": f"{store.get('source_host', '')} — les prochaines sauvegardes échoueront.",
                "remediation": "Lance un prune/GC, ou ajoute de la capacité.",
                "target": store["name"],
                "source": store.get("source", "pbs"),
            })
        elif store["percent"] >= STORE_WARN:
            risks.append({
                "severity": "medium",
                "title": f"Datastore {store['name']} à {store['percent']:.0f} %",
                "detail": store.get("estimated_full")
                and f"Saturation estimée : {store['estimated_full']}" or "",
                "remediation": "Anticipe un prune ou une extension.",
                "target": store["name"],
                "source": store.get("source", "pbs"),
            })

    unverified = [p for p in protected if p["source"] == "pbs" and not p.get("verified")]
    if unverified:
        risks.append({
            "severity": "medium",
            "title": f"{len(unverified)} groupe(s) sans vérification PBS",
            "detail": "Une sauvegarde jamais vérifiée peut être illisible au moment critique.",
            "remediation": "Planifie un job de vérification dans PBS.",
            "target": "vérification",
            "source": "pbs",
        })

    failed = [t for t in tasks
              if t.get("status") not in ("OK", "running", None) and t.get("status")]
    for task in failed[:10]:
        risks.append({
            "severity": "high",
            "title": f"Tâche en échec : {task.get('target') or task.get('type')}",
            "detail": f"{task.get('source_host', '')} — statut « {task.get('status')} ».",
            "remediation": "Consulte le journal de la tâche pour la cause exacte.",
            "target": task.get("target") or "",
            "source": task.get("source", "pbs"),
        })

    order = {"critical": 0, "high": 1, "medium": 2, "low": 3}
    risks.sort(key=lambda r: order.get(r["severity"], 9))
    return risks


# ---------------------------------------------------------------- agrégation
async def overview() -> dict[str, Any]:
    hosts = await fetch_all("SELECT * FROM hosts WHERE enabled")
    by_kind: dict[str, list[dict]] = {}
    for host in hosts:
        by_kind.setdefault(host["kind"], []).append(host)

    sources = [
        *[(_from_pbs, h) for h in by_kind.get("pbs", [])],
        *[(_from_pve, h) for h in by_kind.get("proxmox", [])],
        *[(_from_synology, h) for h in by_kind.get("synology", [])],
    ]
    results = await asyncio.gather(*(fn(host) for fn, host in sources), return_exceptions=True)

    protected: list[dict] = []
    datastores: list[dict] = []
    tasks: list[dict] = []
    errors: list[dict] = []
    notices: list[dict] = []
    for (fn, host), result in zip(sources, results):
        if isinstance(result, Exception):
            errors.append({"host": host["name"], "kind": host["kind"], "error": str(result)[:200]})
            log.info("Protection : %s indisponible (%s)", host["name"], result)
            continue
        protected.extend(result["protected"])
        datastores.extend(result["datastores"])
        tasks.extend(result["tasks"])
        notices.extend(result.get("notices") or [])

    # Les invités Proxmox constituent la population à couvrir.
    guests: list[dict] = []
    live = bus.latest("metrics.")
    for host in by_kind.get("proxmox", []):
        sample = live.get(f"metrics.{host['id']}", {})
        for guest in sample.get("guests") or []:
            guests.append({**guest, "host_id": host["id"]})

    gaps = _find_gaps(protected, guests, hosts)
    risks = _find_risks(protected, datastores, tasks)

    # Règle 3-2-1 : sans copie hors site, un sinistre local emporte tout.
    offsite = [p for p in protected if p.get("offsite")]
    if protected and not offsite:
        risks.insert(0, {
            "severity": "high",
            "title": "Aucune sauvegarde hors site",
            "detail": "Toutes les copies connues restent sur le même site que les données.",
            "remediation": "Ajoute une destination distante : Synology C2, un PBS déporté, "
                           "ou un stockage objet via Hyper Backup.",
            "target": "hors site",
            "source": "global",
        })

    fresh = len([p for p in protected if p["freshness"] == "fresh"])
    total_targets = len(protected) + len(gaps)
    return {
        "protected": sorted(protected, key=lambda p: (p["freshness"] != "fresh", p["name"])),
        "gaps": gaps,
        "risks": risks,
        "datastores": datastores,
        "tasks": sorted(tasks, key=lambda t: t.get("started") or 0, reverse=True)[:40],
        "errors": errors,
        "notices": notices,
        "summary": {
            "offsite": len(offsite),
            "protected": len(protected),
            "fresh": fresh,
            "stale": len([p for p in protected if p["freshness"] == "stale"]),
            "critical": len([p for p in protected if p["freshness"] == "critical"]),
            "gaps": len(gaps),
            "risks": len(risks),
            "risks_critical": len([r for r in risks if r["severity"] == "critical"]),
            # Part des objets connus qui disposent d'une sauvegarde récente.
            "coverage": round(100.0 * fresh / total_targets, 1) if total_targets else 100.0,
            "sources": len(sources),
            "total_size": sum(p.get("size") or 0 for p in protected),
        },
    }
