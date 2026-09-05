from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from typing import Literal

from .. import actions as act
from ..bus import bus
from ..collectors.synology import SynologyError, client_for_host
from ..db import fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/synology", tags=["synology"])


class PackageActionIn(BaseModel):
    package_id: str
    action: Literal["start", "stop"]


class PackageUpgradeIn(BaseModel):
    package_id: str


class PackageUpgradeAllIn(BaseModel):
    """Vide par défaut : sans liste explicite, tout ce que le catalogue propose."""
    package_ids: list[str] | None = None


class TaskActionIn(BaseModel):
    task_id: int
    action: Literal["run", "enable", "disable"]


@router.get("/hosts")
async def syno_hosts(user: dict = Depends(current_user)) -> list[dict]:
    hosts = await fetch_all("SELECT * FROM hosts WHERE kind = 'synology' ORDER BY name")
    live = bus.latest("metrics.")
    for host in hosts:
        sample = live.get(f"metrics.{host['id']}", {})
        host["volumes"] = sample.get("volumes", [])
        host["disks"] = sample.get("disks", [])
        host["pools"] = sample.get("pools", [])
        host["info"] = sample.get("info", host.get("meta", {}))
        host["live"] = {k: v for k, v in sample.items()
                        if isinstance(v, (int, float)) and not isinstance(v, bool)}
    return hosts


@router.get("/{host_id}/packages")
async def packages(host_id: int, user: dict = Depends(current_user)) -> dict:
    """Paquets installés, mises à jour disponibles, et motif en cas d'échec."""
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.packages()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.post("/{host_id}/package/upgrade")
async def upgrade_package(host_id: int, payload: PackageUpgradeIn,
                          user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        result = await client.upgrade_package(payload.package_id)
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()

    from ..poller import log_event
    await log_event(host_id, "info", "synology",
                    f"Mise à jour du paquet {payload.package_id} lancée sur {host['name']} "
                    f"par {user['username']}")
    return {"ok": True, **result}


@router.post("/{host_id}/packages/upgrade-all")
async def upgrade_all_packages(host_id: int, payload: PackageUpgradeAllIn,
                               user: dict = Depends(current_user)) -> dict:
    """Met à jour d'un coup tous les paquets pour lesquels DSM propose une version.

    Chaque paquet est traité séparément : un refus sur l'un n'empêche pas les
    autres, et le détail des échecs est remonté tel quel.
    """
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        wanted = payload.package_ids
        if wanted is None:
            try:
                catalog = await client.packages()
            except SynologyError as exc:
                raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
            wanted = [update["id"] for update in catalog.get("updates") or []]
        if not wanted:
            return {"ok": True, "done": [], "errors": [], "detail": "Aucune mise à jour en attente"}

        done, errors = [], []
        for package_id in wanted:
            try:
                await client.upgrade_package(package_id)
                done.append(package_id)
            except SynologyError as exc:
                errors.append({"package_id": package_id, "error": str(exc)[:200]})
    finally:
        await client.logout()

    from ..poller import log_event
    await log_event(host_id, "warning" if errors else "info", "synology",
                    f"{len(done)} paquet(s) mis à jour sur {host['name']} par {user['username']}"
                    + (f", {len(errors)} en échec" if errors else ""))
    return {"ok": not errors, "done": done, "errors": errors}


@router.get("/{host_id}/dsm-update")
async def dsm_update(host_id: int, user: dict = Depends(current_user)) -> dict:
    """État de la mise à jour du système DSM lui-même."""
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.dsm_update()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.post("/{host_id}/dsm-update/{step}")
async def dsm_update_action(host_id: int, step: Literal["download", "install"],
                            user: dict = Depends(current_user)) -> dict:
    """`download` prépare la mise à jour, `install` l'applique et redémarre le NAS."""
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        result = (await client.dsm_download() if step == "download"
                  else await client.dsm_install())
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()

    from ..poller import log_event
    await log_event(host_id, "warning" if step == "install" else "info", "synology",
                    f"Mise à jour DSM : {'installation lancée' if step == 'install' else 'téléchargement lancé'} "
                    f"sur {host['name']} par {user['username']}")
    return {"ok": True, "step": step, "result": result}


@router.get("/{host_id}/tasks")
async def scheduled_tasks(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.scheduled_tasks()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.post("/{host_id}/tasks")
async def task_action(host_id: int, payload: TaskActionIn,
                      user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        if payload.action == "run":
            await client.run_task(payload.task_id)
        else:
            await client.set_task_enabled(payload.task_id, payload.action == "enable")
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()

    from ..poller import log_event
    labels = {"run": "exécutée", "enable": "activée", "disable": "désactivée"}
    await log_event(host_id, "info", "synology",
                    f"Tâche planifiée #{payload.task_id} {labels[payload.action]} sur "
                    f"{host['name']} par {user['username']}")
    return {"ok": True, "action": payload.action}


@router.get("/{host_id}/services")
async def services(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.services()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.get("/{host_id}/access")
async def access(host_id: int, user: dict = Depends(current_user)) -> dict:
    """Comptes DSM et sessions ouvertes : qui peut entrer, qui est entré."""
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return {"users": await client.users(), "connections": await client.connections()}
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.get("/{host_id}/shares")
async def shares(host_id: int, user: dict = Depends(current_user)) -> list[dict]:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.shares()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.get("/{host_id}/updates")
async def updates(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    client = await client_for_host(host)
    try:
        return await client.check_updates()
    except SynologyError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.logout()


@router.post("/{host_id}/package")
async def package_action(host_id: int, payload: PackageActionIn,
                         user: dict = Depends(current_user)) -> dict:
    host = await _require_syno(host_id)
    try:
        return await act.syno_action(host, payload.action, user["username"], payload.package_id)
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


async def _require_syno(host_id: int) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'synology'", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "NAS Synology introuvable")
    return host
