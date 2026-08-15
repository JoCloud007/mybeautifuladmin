from __future__ import annotations

import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from ..bus import bus
from ..collectors import ipmi as ipmi_col
from ..db import execute, fetch_all, fetch_one
from ..poller import log_event, supervisor
from ..security import current_user

router = APIRouter(prefix="/ipmi", tags=["ipmi"])

PowerAction = Literal["on", "off", "graceful", "restart", "cycle", "nmi"]

ACTION_LABEL = {
    "on": "Allumage",
    "off": "Extinction forcée",
    "graceful": "Extinction propre",
    "restart": "Redémarrage forcé",
    "cycle": "Cycle d'alimentation",
    "nmi": "Interruption NMI",
}


class BmcIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    address: str = Field(min_length=1)
    port: int = 443
    credential_id: int
    mode: Literal["redfish", "ipmitool"] = "redfish"
    secure: bool = True
    proxy_host_id: int | None = None   # machine relais pour ipmitool
    server_host_id: int | None = None  # OS correspondant, pour relier les deux vues
    tags: list[str] = []
    # Enregistrer malgré un diagnostic en échec, pour débrancher plus tard.
    force: bool = False


class DiagnoseIn(BaseModel):
    address: str = Field(min_length=1)
    port: int = 443
    credential_id: int
    secure: bool = True


class BmcPatch(BaseModel):
    name: str | None = None
    address: str | None = None
    port: int | None = None
    credential_id: int | None = None
    mode: Literal["redfish", "ipmitool"] | None = None
    secure: bool | None = None
    proxy_host_id: int | None = None
    server_host_id: int | None = None


@router.post("/diagnose")
async def diagnose(payload: DiagnoseIn, user: dict = Depends(current_user)) -> dict:
    """Teste la chaîne complète avant d'enregistrer, et dit où elle casse."""
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id",
                           {"id": payload.credential_id})
    if not cred:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant introuvable")
    from ..vault import decrypt

    return await ipmi_col.diagnose(
        payload.address, payload.port,
        cred["username"] or "admin", decrypt(cred["secret_enc"]) or "",
        payload.secure,
    )


@router.get("")
async def list_bmcs(user: dict = Depends(current_user)) -> dict:
    hosts = await fetch_all("SELECT * FROM hosts WHERE kind = 'ipmi' ORDER BY name")
    live = bus.latest("metrics.")
    out = []
    for host in hosts:
        sample = live.get(f"metrics.{host['id']}", {})
        meta = host.get("meta") or {}
        server = None
        if meta.get("server_host_id"):
            server = await fetch_one(
                "SELECT id, name, kind, status FROM hosts WHERE id = :id",
                {"id": int(meta["server_host_id"])},
            )
        out.append({
            **host,
            "bmc": sample.get("bmc") or {},
            "temps": sample.get("temps") or {},
            "fans": sample.get("fans") or {},
            "live": {k: v for k, v in sample.items()
                     if isinstance(v, (int, float)) and not isinstance(v, bool)},
            "server": server,
            "mode": meta.get("bmc_mode", "redfish"),
        })
    return {"bmcs": out, "actions": ACTION_LABEL}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_bmc(payload: BmcIn, user: dict = Depends(current_user)) -> dict:
    existing = await fetch_one(
        "SELECT id FROM hosts WHERE address = :a AND kind = 'ipmi'", {"a": payload.address}
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce contrôleur est déjà enregistré")
    if payload.mode == "ipmitool" and not payload.proxy_host_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Le mode ipmitool exige une machine relais")

    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id",
                           {"id": payload.credential_id})
    if not cred:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Identifiant introuvable — crée-le d'abord dans Réglages")

    # On teste avant d'enregistrer : un BMC muet dans la liste n'aide personne.
    if payload.mode == "redfish" and not payload.force:
        from ..vault import decrypt

        result = await ipmi_col.diagnose(
            payload.address, payload.port, cred["username"] or "admin",
            decrypt(cred["secret_enc"]) or "", payload.secure,
        )
        if not result["ok"]:
            failed = next(s for s in result["steps"] if not s["ok"])
            await log_event(None, "warning", "ipmi",
                            f"Ajout du BMC {payload.address} refusé — {failed['detail']}",
                            {"etapes": result["steps"]})
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                {"message": failed["detail"], "hint": failed.get("hint"),
                 "steps": result["steps"],
                 "note": "Coche « Enregistrer quand même » pour l'ajouter malgré tout."},
            )

    meta = {
        "bmc_mode": payload.mode,
        "bmc_secure": payload.secure,
        "bmc_proxy_host_id": payload.proxy_host_id,
        "server_host_id": payload.server_host_id,
    }
    host_id = await execute(
        """INSERT INTO hosts (name, kind, address, port, credential_id, bmc_credential_id,
                              bmc_address, tags, meta, category)
           VALUES (:n, 'ipmi', :a, :p, :c, :c, :a, :t, CAST(:m AS jsonb), 'Hors-bande')
           RETURNING id""",
        {"n": payload.name, "a": payload.address, "p": payload.port,
         "c": payload.credential_id, "t": payload.tags, "m": json.dumps(meta)},
    )
    await supervisor.sync()
    await log_event(host_id, "info", "ipmi",
                    f"Contrôleur BMC « {payload.name} » ajouté ({payload.mode})",
                    {"adresse": payload.address, "port": payload.port})
    return await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})


@router.patch("/{host_id}")
async def update_bmc(host_id: int, payload: BmcPatch, user: dict = Depends(current_user)) -> dict:
    host = await _require_bmc(host_id)
    fields = payload.model_dump(exclude_unset=True)
    meta = dict(host.get("meta") or {})
    for key, target in (("mode", "bmc_mode"), ("secure", "bmc_secure"),
                        ("proxy_host_id", "bmc_proxy_host_id"),
                        ("server_host_id", "server_host_id")):
        if key in fields:
            meta[target] = fields.pop(key)

    sets, params = ["meta = CAST(:meta AS jsonb)"], {"id": host_id, "meta": json.dumps(meta)}
    for key, value in fields.items():
        column = "bmc_credential_id" if key == "credential_id" else key
        sets.append(f"{column} = :{key}")
        params[key] = value
        if key == "credential_id":
            sets.append("credential_id = :credential_id")
        if key == "address":
            sets.append("bmc_address = :address")
    await execute(f"UPDATE hosts SET {', '.join(sets)} WHERE id = :id", params)
    await supervisor.sync()
    return await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})


@router.delete("/{host_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_bmc(host_id: int, user: dict = Depends(current_user)) -> Response:
    await _require_bmc(host_id)
    await supervisor.stop_worker(host_id)
    await execute("DELETE FROM hosts WHERE id = :id", {"id": host_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{host_id}/test")
async def test_bmc(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_bmc(host_id)
    meta = host.get("meta") or {}

    if meta.get("bmc_mode") == "redfish":
        cred = await fetch_one(
            "SELECT * FROM credentials WHERE id = :id",
            {"id": host.get("bmc_credential_id") or host.get("credential_id")},
        )
        if not cred:
            return {"ok": False, "detail": "Aucun identifiant associé"}
        from ..vault import decrypt

        result = await ipmi_col.diagnose(
            host.get("bmc_address") or host["address"], host.get("port") or 443,
            cred["username"] or "admin", decrypt(cred["secret_enc"]) or "",
            meta.get("bmc_secure", True),
        )
        failed = next((s for s in result["steps"] if not s["ok"]), None)
        return {
            "ok": result["ok"],
            "detail": failed["detail"] if failed else result["steps"][-1]["detail"],
            "steps": result["steps"],
            "snapshot": result.get("snapshot"),
        }

    try:
        client = await ipmi_col.client_for_host(host)
        snap = await client.snapshot()
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "detail": str(exc)[:300]}
    return {
        "ok": True,
        "detail": f"{snap.get('model') or 'BMC'} · alimentation {snap.get('power_state')} · "
                  f"{len(snap.get('temps') or {})} capteur(s)",
        "snapshot": snap,
    }


@router.get("/{host_id}/sel")
async def sel(host_id: int, limit: int = 60, user: dict = Depends(current_user)) -> list[dict]:
    host = await _require_bmc(host_id)
    try:
        client = await ipmi_col.client_for_host(host)
        return await client.sel(limit)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc


@router.post("/{host_id}/power/{action}")
async def power(host_id: int, action: PowerAction, user: dict = Depends(current_user)) -> dict:
    host = await _require_bmc(host_id)
    log_id = await execute(
        "INSERT INTO action_logs (host_id, action, status, username) "
        "VALUES (:h, :a, 'running', :u) RETURNING id",
        {"h": host_id, "a": f"ipmi {action}", "u": user["username"]},
    )
    try:
        client = await ipmi_col.client_for_host(host)
        result = await client.power(action)
    except Exception as exc:  # noqa: BLE001
        await execute("UPDATE action_logs SET status='failed', output=:o, ended_at=now() WHERE id=:id",
                      {"o": str(exc)[:2000], "id": log_id})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc

    await execute("UPDATE action_logs SET status='success', output=:o, ended_at=now() WHERE id=:id",
                  {"o": f"{ACTION_LABEL[action]} → {result}", "id": log_id})
    await log_event(host_id, "warning", "ipmi",
                    f"{ACTION_LABEL[action]} demandé sur {host['name']} par {user['username']}")
    return {"ok": True, "action": action, "result": result}


@router.post("/{host_id}/identify")
async def identify(host_id: int, on: bool = True, user: dict = Depends(current_user)) -> dict:
    host = await _require_bmc(host_id)
    try:
        client = await ipmi_col.client_for_host(host)
        await client.identify(on)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc
    return {"ok": True, "identify": on}


async def _require_bmc(host_id: int) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'ipmi'", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Contrôleur BMC introuvable")
    return host
