from __future__ import annotations

import asyncio
import json
import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Response, WebSocket, WebSocketDisconnect, status
from pydantic import BaseModel, Field

from .. import discovery as scan_mod
from ..collectors import tailscale as ts
from ..config import settings
from ..db import execute, execute_many, fetch_all, fetch_one
from ..poller import supervisor
from ..security import current_user, ws_user
from ..vault import decrypt

log = logging.getLogger("mba.discovery.api")
router = APIRouter(prefix="/discovery", tags=["discovery"])


class ScanIn(BaseModel):
    targets: str = Field(min_length=1, description="CIDR, IP ou plage, séparés par des virgules")
    ports: list[int] | None = None
    concurrency: int = Field(256, ge=16, le=1024)


class AdoptIn(BaseModel):
    address: str
    name: str | None = None
    kind: str | None = None
    port: int | None = None
    credential_id: int | None = None
    tags: list[str] = []
    category: str | None = None


DEFAULT_PORTS = {"linux": 22, "proxmox": 8006, "synology": 5001, "docker": 22,
                 "ollama": 11434, "generic": 80}


@router.get("/suggestions")
async def suggestions(user: dict = Depends(current_user)) -> dict:
    """Sous-réseaux proposés : ceux de la config plus celui du conteneur."""
    subnets = [s.strip() for s in settings.discovery_subnets.split(",") if s.strip()]
    if not subnets:
        import socket
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.connect(("1.1.1.1", 80))
            local = sock.getsockname()[0]
            sock.close()
            subnets = [".".join(local.split(".")[:3]) + ".0/24"]
        except OSError:
            subnets = ["192.168.1.0/24"]
    return {"subnets": subnets, "ports": scan_mod.SCAN_PORTS}


@router.get("/results")
async def results(user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        """SELECT d.*, h.id AS host_id FROM discovery_results d
           LEFT JOIN hosts h ON h.address = d.address
           WHERE NOT d.ignored ORDER BY d.seen_at DESC"""
    )


@router.post("/scan")
async def run_scan(payload: ScanIn, user: dict = Depends(current_user)) -> dict:
    """Scan synchrone — pratique pour l'API ; l'UI utilise plutôt le WebSocket."""
    try:
        found = await scan_mod.scan(payload.targets, payload.ports, payload.concurrency)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc
    await _persist(found)
    return {"count": len(found), "results": [c.as_dict() for c in found]}


@router.websocket("/ws")
async def scan_ws(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        user = await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return
    del user

    try:
        request = json.loads(await websocket.receive_text())
    except (WebSocketDisconnect, json.JSONDecodeError):
        await websocket.close(code=4400)
        return

    targets = request.get("targets") or ""
    ports = request.get("ports") or None
    concurrency = min(int(request.get("concurrency") or 256), 1024)

    async def progress(message: dict) -> None:
        try:
            await websocket.send_text(json.dumps(message, default=str))
        except (WebSocketDisconnect, RuntimeError):
            raise asyncio.CancelledError from None

    try:
        found = await scan_mod.scan(targets, ports, concurrency, progress=progress)
    except ValueError as exc:
        await websocket.send_text(json.dumps({"type": "error", "message": str(exc)}))
        await websocket.close()
        return
    except asyncio.CancelledError:
        return

    await _persist(found)
    known = {h["address"] for h in await fetch_all("SELECT address FROM hosts")}
    await websocket.send_text(json.dumps({
        "type": "done",
        "count": len(found),
        "results": [{**c.as_dict(), "known": c.address in known} for c in found],
    }, default=str))
    await websocket.close()


# ------------------------------------------------------------------ Tailscale
class TailscaleIn(BaseModel):
    source: Literal["api", "host"] = "api"
    credential_id: int | None = None   # credential api_token contenant la clé
    api_key: str | None = None         # ou clé fournie à la volée (non stockée)
    tailnet: str = "-"
    host_id: int | None = None         # pour source = host
    probe_ports: bool = True


async def _tailscale_devices(payload: TailscaleIn) -> list[dict]:
    if payload.source == "host":
        if not payload.host_id:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Choisis la machine qui porte le client Tailscale")
        host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": payload.host_id})
        if not host:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Hôte introuvable")
        return await ts.devices_from_host(host)

    key = payload.api_key
    if not key and payload.credential_id:
        cred = await fetch_one("SELECT * FROM credentials WHERE id = :id",
                               {"id": payload.credential_id})
        if not cred:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant introuvable")
        key = decrypt(cred["secret_enc"])
    if not key:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Clé d'API Tailscale requise")
    return await ts.devices_from_api(key, payload.tailnet)


@router.post("/tailscale")
async def tailscale_scan(payload: TailscaleIn, user: dict = Depends(current_user)) -> dict:
    try:
        devices = await _tailscale_devices(payload)
    except ts.TailscaleError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc

    # Sonde de ports optionnelle : elle n'aboutit que si MBA est sur le tailnet.
    if payload.probe_ports:
        online = [d for d in devices if d["online"] and d["address"]]
        results = await asyncio.gather(
            *(scan_mod.scan_host(d["address"], scan_mod.SCAN_PORTS, asyncio.Semaphore(64))
              for d in online),
            return_exceptions=True,
        )
        for device, found in zip(online, results):
            if isinstance(found, scan_mod.Candidate):
                device["open_ports"] = sorted(found.open_ports)
                device["evidence"] = found.evidence
                # L'empreinte de service est plus fiable que l'OS déclaré.
                if found.guessed_kind != "generic":
                    device["guessed_kind"] = found.guessed_kind
                device["reachable"] = True
            else:
                device["reachable"] = False

    await _persist_tailscale(devices)
    known = {h["address"] for h in await fetch_all("SELECT address FROM hosts")}
    known_ids = {h["tailscale_id"] for h in
                 await fetch_all("SELECT tailscale_id FROM hosts WHERE tailscale_id IS NOT NULL")}
    for device in devices:
        device["known"] = device["address"] in known or device["tailscale_id"] in known_ids

    return {
        "devices": devices,
        "summary": {
            "total": len(devices),
            "online": len([d for d in devices if d["online"]]),
            "known": len([d for d in devices if d["known"]]),
            "updates": len([d for d in devices if d.get("update_available")]),
        },
    }


async def _persist_tailscale(devices: list[dict]) -> None:
    rows = [{
        "address": d["address"], "hostname": d["dns_name"] or d["hostname"],
        "kind": d["guessed_kind"], "ports": d.get("open_ports") or [],
        "evidence": json.dumps(d.get("evidence") or {}, default=str),
        "meta": json.dumps({k: d.get(k) for k in
                            ("tailscale_id", "os", "version", "tags", "online",
                             "last_seen", "user", "update_available")}, default=str),
    } for d in devices if d.get("address")]
    if not rows:
        return
    await execute_many(
        """INSERT INTO discovery_results (address, hostname, guessed_kind, open_ports,
                                          evidence, meta, source, seen_at)
           VALUES (:address, :hostname, :kind, :ports, CAST(:evidence AS jsonb),
                   CAST(:meta AS jsonb), 'tailscale', now())
           ON CONFLICT (address) DO UPDATE SET
             hostname = EXCLUDED.hostname, guessed_kind = EXCLUDED.guessed_kind,
             open_ports = EXCLUDED.open_ports, evidence = EXCLUDED.evidence,
             meta = EXCLUDED.meta, source = 'tailscale', seen_at = now()""",
        rows,
    )


@router.post("/tailscale/test")
async def tailscale_test(payload: TailscaleIn, user: dict = Depends(current_user)) -> dict:
    try:
        devices = await _tailscale_devices(payload)
    except ts.TailscaleError as exc:
        return {"ok": False, "detail": str(exc)}
    return {"ok": True, "detail": f"{len(devices)} machine(s), "
                                  f"{len([d for d in devices if d['online']])} en ligne"}


@router.post("/adopt", status_code=status.HTTP_201_CREATED)
async def adopt(payload: AdoptIn, user: dict = Depends(current_user)) -> dict:
    found = await fetch_one("SELECT * FROM discovery_results WHERE address = :a", {"a": payload.address})
    kind = payload.kind or (found or {}).get("guessed_kind") or "generic"
    if kind == "ollama":
        # Un endpoint Ollama n'est pas un hôte : on l'enregistre côté IA.
        endpoint_id = await execute(
            "INSERT INTO ai_endpoints (name, url, kind) VALUES (:n, :u, 'ollama') RETURNING id",
            {"n": payload.name or f"ollama-{payload.address}", "u": f"http://{payload.address}:11434"},
        )
        await execute("UPDATE discovery_results SET adopted = true WHERE address = :a", {"a": payload.address})
        return {"type": "ai_endpoint", "id": endpoint_id}

    port = payload.port or DEFAULT_PORTS.get(kind, 22)
    existing = await fetch_one(
        "SELECT id FROM hosts WHERE address=:a AND kind=:k AND port=:p",
        {"a": payload.address, "k": kind, "p": port},
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet hôte est déjà enregistré")

    name = payload.name or (found or {}).get("hostname") or payload.address
    discovered_meta = (found or {}).get("meta") or {}
    host_id = await execute(
        """INSERT INTO hosts (name, kind, address, port, credential_id, tags, meta,
                            category, tailscale_id)
           VALUES (:n, :k, :a, :p, :c, :t, CAST(:m AS jsonb), :cat, :tsid) RETURNING id""",
        {"n": name.split(".")[0], "k": kind, "a": payload.address, "p": port,
         "c": payload.credential_id,
         "t": payload.tags or discovered_meta.get("tags") or [],
         "m": json.dumps({"discovered": True, "source": (found or {}).get("source", "network"),
                          "evidence": (found or {}).get("evidence", {}),
                          **{k: discovered_meta[k] for k in ("os", "version", "user")
                             if discovered_meta.get(k)}}, default=str),
         "cat": payload.category,
         "tsid": discovered_meta.get("tailscale_id")},
    )
    await execute("UPDATE discovery_results SET adopted = true WHERE address = :a", {"a": payload.address})
    await supervisor.sync()
    return {"type": "host", "id": host_id}


@router.post("/ignore/{address}")
async def ignore(address: str, user: dict = Depends(current_user)) -> dict:
    await execute("UPDATE discovery_results SET ignored = true WHERE address = :a", {"a": address})
    return {"ok": True}


@router.delete("/results", status_code=status.HTTP_204_NO_CONTENT)
async def clear_results(user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM discovery_results WHERE NOT adopted")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


async def _persist(found: list[scan_mod.Candidate]) -> None:
    if not found:
        return
    await execute_many(
        """INSERT INTO discovery_results (address, hostname, guessed_kind, open_ports, evidence, seen_at)
           VALUES (:address, :hostname, :kind, :ports, CAST(:evidence AS jsonb), now())
           ON CONFLICT (address) DO UPDATE SET
             hostname = EXCLUDED.hostname, guessed_kind = EXCLUDED.guessed_kind,
             open_ports = EXCLUDED.open_ports, evidence = EXCLUDED.evidence, seen_at = now()""",
        [{"address": c.address, "hostname": c.hostname, "kind": c.guessed_kind,
          "ports": sorted(c.open_ports), "evidence": json.dumps(c.evidence, default=str)}
         for c in found],
    )
