from __future__ import annotations

import json

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from ..bus import bus
from ..collectors import homeassistant as hass_col
from ..db import execute, fetch_all, fetch_one
from ..poller import log_event, supervisor
from ..security import current_user

router = APIRouter(prefix="/home", tags=["domotique"])

# Services autorisés depuis MBA : on reste sur des gestes réversibles.
ALLOWED_SERVICES = {
    "turn_on", "turn_off", "toggle", "open_cover", "close_cover", "stop_cover",
    "press", "trigger",
}


class HassIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    address: str = Field(min_length=1)
    port: int = 8123
    credential_id: int
    secure: bool = False
    url: str | None = None


class ServiceCall(BaseModel):
    entity_id: str = Field(min_length=3)
    service: str = Field(min_length=2)


@router.get("")
async def overview(user: dict = Depends(current_user)) -> dict:
    hubs = await fetch_all("SELECT * FROM hosts WHERE kind = 'homeassistant' ORDER BY name")
    live = bus.latest("metrics.")
    out = []
    for hub in hubs:
        sample = live.get(f"metrics.{hub['id']}", {})
        out.append({
            **hub,
            "entities": sample.get("entities", []),
            "by_domain": sample.get("by_domain", {}),
            "stats": sample.get("hass", {}),
        })
    return {"hubs": out, "domain_labels": hass_col.DOMAIN_LABEL}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_hub(payload: HassIn, user: dict = Depends(current_user)) -> dict:
    existing = await fetch_one(
        "SELECT id FROM hosts WHERE address = :a AND kind = 'homeassistant'",
        {"a": payload.address},
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cette instance est déjà enregistrée")

    # On valide le jeton avant d'enregistrer : un hub muet n'aide personne.
    probe = {
        "name": payload.name, "address": payload.address, "port": payload.port,
        "credential_id": payload.credential_id,
        "meta": {"secure": payload.secure, "url": payload.url},
    }
    try:
        client = await hass_col.client_for_host(probe)
        info = await client.ping()
    except hass_col.HomeAssistantError as exc:
        await log_event(None, "warning", "domotique",
                        f"Ajout de Home Assistant refusé — {exc}",
                        {"adresse": payload.address, "port": payload.port,
                         "https": payload.secure})
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            {"message": str(exc),
             "hint": f"URL testée : {'https' if payload.secure else 'http'}://"
                     f"{payload.address}:{payload.port}/api/ — vérifie qu'elle répond "
                     "depuis le conteneur MBA."},
        ) from exc

    host_id = await execute(
        """INSERT INTO hosts (name, kind, address, port, credential_id, meta, category)
           VALUES (:n, 'homeassistant', :a, :p, :c, CAST(:m AS jsonb), 'Domotique')
           RETURNING id""",
        {"n": payload.name, "a": payload.address, "p": payload.port, "c": payload.credential_id,
         "m": json.dumps({"secure": payload.secure, "url": payload.url,
                          "version": info.get("version"), "location": info.get("location")})},
    )
    await supervisor.sync()
    await log_event(host_id, "info", "domotique",
                    f"Home Assistant « {payload.name} » ajouté (version {info.get('version')})",
                    {"entites": info.get("components")})
    return await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})


@router.delete("/{host_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_hub(host_id: int, user: dict = Depends(current_user)) -> Response:
    await _require_hub(host_id)
    await supervisor.stop_worker(host_id)
    await execute("DELETE FROM hosts WHERE id = :id", {"id": host_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{host_id}/test")
async def test_hub(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_hub(host_id)
    try:
        client = await hass_col.client_for_host(host)
        info = await client.ping()
    except hass_col.HomeAssistantError as exc:
        return {"ok": False, "detail": str(exc)}
    return {"ok": True,
            "detail": f"Home Assistant {info.get('version')} · {info.get('location') or ''}",
            "info": info}


@router.post("/{host_id}/call")
async def call_service(host_id: int, payload: ServiceCall,
                       user: dict = Depends(current_user)) -> dict:
    host = await _require_hub(host_id)
    if payload.service not in ALLOWED_SERVICES:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"Service non autorisé depuis MBA : {payload.service}")
    domain = payload.entity_id.split(".")[0]

    client = await hass_col.client_for_host(host)
    try:
        await client.call_service(domain, payload.service, payload.entity_id)
    except hass_col.HomeAssistantError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc

    await log_event(host_id, "info", "domotique",
                    f"{payload.service} sur {payload.entity_id} par {user['username']}")
    # L'état met une seconde à se propager : on force un cycle rapproché.
    worker = supervisor.workers.get(host_id)
    if worker:
        worker.last_containers = 0
    return {"ok": True, "entity_id": payload.entity_id, "service": payload.service}


@router.get("/{host_id}/history/{entity_id}")
async def history(host_id: int, entity_id: str, hours: int = 24,
                  user: dict = Depends(current_user)) -> list[dict]:
    host = await _require_hub(host_id)
    client = await hass_col.client_for_host(host)
    try:
        return await client.history(entity_id, hours)
    except hass_col.HomeAssistantError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.get("/{host_id}/log")
async def error_log(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_hub(host_id)
    client = await hass_col.client_for_host(host)
    return {"log": await client.error_log()}


async def _require_hub(host_id: int) -> dict:
    host = await fetch_one(
        "SELECT * FROM hosts WHERE id = :id AND kind = 'homeassistant'", {"id": host_id}
    )
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Instance Home Assistant introuvable")
    return host
