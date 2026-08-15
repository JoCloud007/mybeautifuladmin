from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from .. import audit as engine
from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/security", tags=["sécurité"])


class MuteIn(BaseModel):
    muted: bool = True


@router.get("")
async def overview(user: dict = Depends(current_user)) -> dict:
    """Constats ouverts, sans relancer l'analyse (elle tourne en tâche de fond)."""
    return await engine.summary()


@router.post("/scan")
async def rescan(user: dict = Depends(current_user)) -> dict:
    return await engine.scan()


@router.post("/findings/{finding_id}/mute")
async def mute(finding_id: int, payload: MuteIn, user: dict = Depends(current_user)) -> dict:
    row = await fetch_one("SELECT id FROM security_findings WHERE id = :id", {"id": finding_id})
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Constat introuvable")
    await execute("UPDATE security_findings SET muted = :m WHERE id = :id",
                  {"m": payload.muted, "id": finding_id})
    return {"ok": True, "muted": payload.muted}


@router.get("/muted")
async def muted(user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        "SELECT f.*, h.name AS host_name FROM security_findings f "
        "LEFT JOIN hosts h ON h.id = f.host_id "
        "WHERE f.muted AND f.resolved_at IS NULL ORDER BY f.last_seen DESC"
    )


@router.get("/history")
async def history(user: dict = Depends(current_user)) -> list[dict]:
    """Constats clos sur 30 jours : utile pour montrer que la dette baisse."""
    return await fetch_all(
        "SELECT f.*, h.name AS host_name FROM security_findings f "
        "LEFT JOIN hosts h ON h.id = f.host_id "
        "WHERE f.resolved_at > now() - interval '30 days' "
        "ORDER BY f.resolved_at DESC LIMIT 200"
    )
