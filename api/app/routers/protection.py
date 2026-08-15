from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from .. import protection as engine
from ..collectors import pbs as pbs_col
from ..db import fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/protection", tags=["protection"])


class PbsTestIn(BaseModel):
    address: str = Field(min_length=1)
    port: int = 8007
    credential_id: int


@router.get("")
async def overview(user: dict = Depends(current_user)) -> dict:
    """Couverture, écarts et risques, agrégés sur toutes les sources."""
    return await engine.overview()


@router.get("/sources")
async def sources(user: dict = Depends(current_user)) -> dict:
    """Sources de sauvegarde connues, pour guider la configuration."""
    hosts = await fetch_all(
        "SELECT id, name, kind, address, status FROM hosts "
        "WHERE kind IN ('pbs', 'proxmox', 'synology') ORDER BY kind, name"
    )
    return {
        "sources": hosts,
        "has_pbs": any(h["kind"] == "pbs" for h in hosts),
        "thresholds": {
            "stale_hours": engine.STALE_HOURS,
            "critical_hours": engine.CRITICAL_HOURS,
            "store_warn": engine.STORE_WARN,
            "store_crit": engine.STORE_CRIT,
        },
    }


@router.post("/test-pbs")
async def test_pbs(payload: PbsTestIn, user: dict = Depends(current_user)) -> dict:
    """Vérifie l'accès à un PBS avant de l'enregistrer comme hôte."""
    host = {
        "name": "test",
        "address": payload.address,
        "port": payload.port,
        "credential_id": payload.credential_id,
    }
    client = await pbs_col.client_for_host(host)
    try:
        stores = await client.datastores()
    except pbs_col.PBSError as exc:
        return {"ok": False, "detail": str(exc)}
    finally:
        await client.close()
    return {
        "ok": True,
        "detail": f"{len(stores)} datastore(s) : "
                  + ", ".join(f"{s['name']} ({s['percent']:.0f} %)" for s in stores),
        "datastores": stores,
    }


@router.get("/{host_id}/snapshots/{store}")
async def snapshots(host_id: int, store: str, user: dict = Depends(current_user)) -> list[dict]:
    """Détail des instantanés d'un datastore PBS."""
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'pbs'", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Serveur de sauvegarde introuvable")
    client = await pbs_col.client_for_host(host)
    try:
        return await client.snapshots(store)
    except pbs_col.PBSError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()
