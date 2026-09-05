"""Mises à jour du parc : état consolidé et exécution par lot.

Trois familles cohabitent, avec chacune sa notion de « à jour » :

* les **paquets système** des hôtes Linux — relevés par le collecteur toutes les
  cinq minutes, appliqués par SSH ;
* les **piles Docker** — mettre à jour, c'est récupérer les images puis recréer
  les conteneurs (`compose pull && up -d`) ;
* les **NAS Synology** — DSM et ses paquets, pilotés par l'API DSM.

Seule la troisième coûte cher : plusieurs requêtes HTTP par NAS, quelques
secondes chacune. Elle est donc mise en cache et rafraîchie à la demande, pour
qu'un simple affichage de la page ne réveille pas tous les NAS.

Les traitements par lot ne bloquent pas la requête HTTP : ils partent en tâches
de fond et se suivent dans le journal des actions, comme les actions unitaires.
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from .. import actions as act
from ..collectors.synology import SynologyError, client_for_host
from ..db import execute, fetch_all
from ..security import current_user

log = logging.getLogger("mba.updates")

router = APIRouter(prefix="/updates", tags=["mises à jour"])

# Hôtes que MBA sait mettre à jour lui-même (SSH + gestionnaire de paquets).
UPGRADABLE_KINDS = {"linux", "docker", "proxmox"}
# Deux mises à jour de paquets en parallèle : au-delà, on sature le réseau et on
# rend les journaux illisibles sans rien gagner.
MAX_PARALLEL = 2
SYNO_TTL = 300.0

_syno_cache: dict[int, tuple[float, dict]] = {}
# Les tâches de fond doivent garder une référence forte, sinon le ramasse-miettes
# peut les interrompre en plein milieu.
_running: set[asyncio.Task] = set()


# ------------------------------------------------------------------- lecture
def _host_row(host: dict) -> dict[str, Any]:
    meta = host.get("meta") or {}
    updates = int(meta.get("updates") or 0)
    security = int(meta.get("security_updates") or 0)
    kernel_stale = bool(
        meta.get("kernel_running")
        and meta.get("kernel_installed")
        and meta["kernel_running"] != meta["kernel_installed"]
    )
    return {
        "id": host["id"],
        "name": host["name"],
        "kind": host["kind"],
        "address": host["address"],
        "status": host["status"],
        "tags": host.get("tags") or [],
        "os": meta.get("os"),
        "updates": updates,
        "security_updates": security,
        "reboot_required": bool(meta.get("reboot_required")) or kernel_stale,
        "kernel_stale": kernel_stale,
        "kernel_running": meta.get("kernel_running"),
        "kernel_installed": meta.get("kernel_installed"),
        "auto_updates": bool(meta.get("auto_updates")),
        "last_seen": host.get("last_seen"),
        # « local » est le socket Docker monté dans le conteneur MBA : pas de SSH,
        # donc rien à mettre à jour de ce côté.
        "upgradable": host["kind"] in UPGRADABLE_KINDS and host["address"] != "local",
    }


async def _syno_state(host: dict, refresh: bool) -> dict[str, Any]:
    """Paquets et DSM d'un NAS, avec cache : l'API DSM est lente."""
    cached = _syno_cache.get(host["id"])
    if cached and not refresh and time.time() - cached[0] < SYNO_TTL:
        return cached[1]

    state: dict[str, Any] = {
        "host_id": host["id"], "name": host["name"], "tags": host.get("tags") or [],
        "packages": [], "dsm": None, "reason": None, "error": None,
    }
    try:
        client = await client_for_host(host)
    except SynologyError as exc:
        state["error"] = str(exc)[:200]
        _syno_cache[host["id"]] = (time.time(), state)
        return state

    try:
        catalog = await asyncio.wait_for(client.packages(), timeout=45)
        state["packages"] = catalog.get("updates") or []
        state["reason"] = catalog.get("reason")
        state["dsm"] = await asyncio.wait_for(client.dsm_update(), timeout=45)
    except asyncio.TimeoutError:
        state["error"] = "Le NAS n'a pas répondu à temps."
    except Exception as exc:  # noqa: BLE001
        state["error"] = str(exc)[:200]
    finally:
        await client.logout()

    _syno_cache[host["id"]] = (time.time(), state)
    return state


@router.get("")
async def overview(refresh: bool = False, user: dict = Depends(current_user)) -> dict:
    """État des mises à jour, toutes familles confondues."""
    # `*` et non une liste de colonnes : les NAS ont besoin de leur identifiant
    # de credential et de leur port pour qu'on puisse ouvrir une session DSM.
    hosts = await fetch_all(
        "SELECT *, coalesce(tags, '{}') AS tags FROM hosts WHERE enabled ORDER BY name"
    )
    rows = [_host_row(host) for host in hosts]
    # On ne garde que ce qui a quelque chose à dire : soit du retard, soit la
    # capacité d'être mis à jour depuis MBA.
    machines = [r for r in rows if r["updates"] or r["reboot_required"] or r["upgradable"]]

    stacks = await fetch_all(
        """SELECT c.host_id, h.name AS host_name, c.project,
                  coalesce(h.tags, '{}') AS tags,
                  count(*) AS total,
                  count(*) FILTER (WHERE c.state = 'running') AS running,
                  count(*) FILTER (WHERE c.image LIKE :floating) AS floating,
                  max(c.updated_at) AS updated_at
           FROM containers c JOIN hosts h ON h.id = c.host_id
           WHERE c.kind = 'docker' AND c.project IS NOT NULL AND h.enabled
           GROUP BY c.host_id, h.name, c.project, h.tags
           ORDER BY h.name, c.project""",
        # Écrit en dur, « :latest » serait pris pour un paramètre nommé.
        {"floating": "%:latest"},
    )

    nas = [h for h in hosts if h["kind"] == "synology"]
    synology = list(await asyncio.gather(*(_syno_state(h, refresh) for h in nas))) if nas else []

    dsm_pending = sum(1 for entry in synology if (entry.get("dsm") or {}).get("available"))
    return {
        "hosts": machines,
        "stacks": stacks,
        "synology": synology,
        "summary": {
            "hosts": len(machines),
            "hosts_pending": sum(1 for r in machines if r["updates"]),
            "packages": sum(r["updates"] for r in machines),
            "security": sum(r["security_updates"] for r in machines),
            "reboot_required": sum(1 for r in machines if r["reboot_required"]),
            "auto_updates": sum(1 for r in machines if r["auto_updates"]),
            "offline": sum(1 for r in machines if r["status"] == "offline"),
            "stacks": len(stacks),
            "floating_images": sum(s["floating"] for s in stacks),
            "syno_packages": sum(len(entry["packages"]) for entry in synology),
            "dsm_pending": dsm_pending,
        },
    }


@router.get("/activity")
async def activity(user: dict = Depends(current_user)) -> dict:
    """Ce que MBA est en train d'appliquer, ou vient d'appliquer."""
    rows = await fetch_all(
        """SELECT a.id, a.host_id, h.name AS host_name, a.target, a.action, a.status,
                  a.started_at, a.ended_at, left(coalesce(a.output, ''), 600) AS excerpt
           FROM action_logs a LEFT JOIN hosts h ON h.id = a.host_id
           WHERE a.action IN ('upgrade', 'reboot', 'compose update', 'docker pull')
             AND a.started_at > now() - interval '12 hours'
           ORDER BY a.started_at DESC LIMIT 60"""
    )
    return {"entries": rows, "running": sum(1 for r in rows if r["status"] == "running")}


# ------------------------------------------------------------------- écriture
class HostBatchIn(BaseModel):
    host_ids: list[int] = Field(min_length=1)
    action: Literal["upgrade", "reboot"] = "upgrade"


class StackTarget(BaseModel):
    host_id: int
    project: str


class StackBatchIn(BaseModel):
    targets: list[StackTarget] = Field(min_length=1)


def _spawn(coro) -> None:
    task = asyncio.create_task(coro)
    _running.add(task)
    task.add_done_callback(_running.discard)


@router.post("/hosts")
async def batch_hosts(payload: HostBatchIn, user: dict = Depends(current_user)) -> dict:
    """Met à jour (ou redémarre) plusieurs hôtes, deux à la fois.

    La requête rend la main tout de suite : une mise à jour de paquets peut durer
    plusieurs minutes, et on ne veut ni bloquer l'interface ni dépendre du délai
    d'expiration d'un proxy. La suite se lit dans `/updates/activity`.
    """
    hosts = await fetch_all(
        "SELECT * FROM hosts WHERE enabled AND id = ANY(CAST(:ids AS integer[]))",
        {"ids": payload.host_ids},
    )
    if not hosts:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Aucun hôte correspondant")

    started, skipped = [], []
    eligible = []
    for host in hosts:
        if host["kind"] not in UPGRADABLE_KINDS or host["address"] == "local":
            skipped.append({"name": host["name"], "reason": "Hôte non gérable par SSH"})
        elif host["status"] == "offline":
            skipped.append({"name": host["name"], "reason": "Hôte injoignable"})
        else:
            eligible.append(host)
            started.append({"id": host["id"], "name": host["name"]})

    semaphore = asyncio.Semaphore(MAX_PARALLEL)
    username = user["username"]

    async def worker(host: dict) -> None:
        async with semaphore:
            try:
                if payload.action == "upgrade":
                    await act.upgrade_host(host, username)
                else:
                    await act.power_action(host, "reboot", username)
            except Exception as exc:  # noqa: BLE001
                log.warning("Lot de mise à jour : %s a échoué (%s)", host["name"], exc)

    for host in eligible:
        _spawn(worker(host))

    if started:
        from ..poller import log_event

        await log_event(None, "info", "action",
                        f"Lot de {payload.action} lancé sur {len(started)} hôte(s) par {username}",
                        {"hosts": [h["name"] for h in started]})
    return {"started": started, "skipped": skipped}


@router.post("/stacks")
async def batch_stacks(payload: StackBatchIn, user: dict = Depends(current_user)) -> dict:
    """`compose pull && up -d` sur plusieurs piles, une à la fois par hôte."""
    started, skipped = [], []
    jobs: list[tuple[dict, str, str | None]] = []

    for target in payload.targets:
        rows = await fetch_all(
            "SELECT h.*, c.labels FROM containers c JOIN hosts h ON h.id = c.host_id "
            "WHERE c.host_id = :h AND c.project = :p AND c.kind = 'docker' LIMIT 5",
            {"h": target.host_id, "p": target.project},
        )
        if not rows:
            skipped.append({"project": target.project, "reason": "Pile introuvable"})
            continue
        host = {k: v for k, v in rows[0].items() if k != "labels"}
        workdir = next(
            (r["labels"].get("com.docker.compose.project.working_dir")
             for r in rows if (r["labels"] or {}).get("com.docker.compose.project.working_dir")),
            None,
        )
        jobs.append((host, target.project, workdir))
        started.append({"host_id": host["id"], "host_name": host["name"], "project": target.project})

    if not jobs:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Aucune pile correspondante")

    from ..collectors.docker import compose_update

    semaphore = asyncio.Semaphore(MAX_PARALLEL)
    username = user["username"]

    async def worker(host: dict, project: str, workdir: str | None) -> None:
        async with semaphore:
            log_id = await execute(
                "INSERT INTO action_logs (host_id, target, action, status, username) "
                "VALUES (:h, :t, 'compose update', 'running', :u) RETURNING id",
                {"h": host["id"], "t": project, "u": username},
            )
            try:
                result = await compose_update(host, project, workdir)
            except Exception as exc:  # noqa: BLE001
                await execute(
                    "UPDATE action_logs SET status='failed', output=:o, ended_at=now() WHERE id=:id",
                    {"o": str(exc)[:8000], "id": log_id},
                )
                return
            await execute(
                "UPDATE action_logs SET status='success', output=:o, ended_at=now() WHERE id=:id",
                {"o": (result.get("output") or "")[:16000], "id": log_id},
            )
            await act._refresh_containers_later(host["id"], delay=4.0)

    for host, project, workdir in jobs:
        _spawn(worker(host, project, workdir))

    from ..poller import log_event

    await log_event(None, "info", "action",
                    f"Lot de mise à jour lancé sur {len(started)} pile(s) par {username}")
    return {"started": started, "skipped": skipped}
