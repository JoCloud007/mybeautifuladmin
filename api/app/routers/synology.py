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
