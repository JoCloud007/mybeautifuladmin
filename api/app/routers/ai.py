from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator

from ..bus import bus
from ..collectors.aiclient import KINDS, UnsupportedOperation, capabilities, client_for, normalize_kind
from ..db import execute, fetch_all, fetch_one
from ..security import current_user
from ..vault import decrypt, encrypt

router = APIRouter(prefix="/ai", tags=["ai"])

# La clé d'API ne ressort jamais de la base : on énumère les colonnes plutôt
# que de faire confiance à un SELECT *.
COLUMNS = ("a.id, a.name, a.url, a.host_id, a.kind, a.enabled, a.status, a.meta, "
           "a.created_at, (a.api_key_enc IS NOT NULL) AS has_key")


class EndpointIn(BaseModel):
    name: str
    url: str
    host_id: int | None = None
    kind: str = "ollama"
    enabled: bool = True
    api_key: str | None = None

    @field_validator("kind")
    @classmethod
    def _kind(cls, value: str) -> str:
        try:
            return normalize_kind(value)
        except ValueError as exc:
            raise ValueError(str(exc)) from exc


class EndpointPatch(BaseModel):
    """Modification partielle : seuls les champs envoyés sont touchés.

    `api_key` obéit à une règle à trois temps : absent, la clé en place est
    conservée ; à `null`, elle est retirée ; renseigné, elle est remplacée.
    """

    name: str | None = None
    url: str | None = None
    host_id: int | None = None
    kind: str | None = None
    enabled: bool | None = None
    api_key: str | None = None

    @field_validator("kind")
    @classmethod
    def _kind(cls, value: str | None) -> str | None:
        if value is None:
            return None
        try:
            return normalize_kind(value)
        except ValueError as exc:
            raise ValueError(str(exc)) from exc


class ChatIn(BaseModel):
    model: str
    messages: list[dict[str, str]]
    temperature: float | None = Field(default=None, ge=0, le=2)
    num_ctx: int | None = None


class PullIn(BaseModel):
    model: str = Field(min_length=1)


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, default=str)}\n\n"


def _decorate(endpoint: dict) -> dict:
    """Ce que l'interface a besoin de savoir pour n'offrir que les gestes possibles."""
    endpoint["capabilities"] = capabilities(endpoint.get("kind"))
    endpoint["kind_label"] = KINDS.get(endpoint.get("kind") or "ollama", {}).get("label", endpoint.get("kind"))
    return endpoint


@router.get("/kinds")
async def list_kinds(user: dict = Depends(current_user)) -> list[dict]:
    return [{"kind": kind, **spec} for kind, spec in KINDS.items()]


@router.get("/overview")
async def overview(user: dict = Depends(current_user)) -> dict:
    endpoints = await fetch_all(
        f"SELECT {COLUMNS}, h.name AS host_name FROM ai_endpoints a "
        "LEFT JOIN hosts h ON h.id = a.host_id ORDER BY a.name"
    )
    live = bus.latest("ai.")
    for ep in endpoints:
        snap = live.get(f"ai.{ep['id']}", {})
        ep["models"] = snap.get("models", [])
        ep["loaded"] = snap.get("loaded", [])
        ep["version"] = snap.get("version")
        ep["status"] = snap.get("status", ep["status"])
        ep["error"] = snap.get("error")
        _decorate(ep)

    # Accélérateurs : on remonte les GPU vus par les collecteurs Linux.
    metrics_live = bus.latest("metrics.")
    accelerators = []
    for topic, sample in metrics_live.items():
        for gpu in sample.get("gpus") or []:
            accelerators.append({
                "host_id": sample.get("_host_id"),
                "host_name": sample.get("_name"),
                "card": gpu["id"],
                "busy": gpu["busy"],
                "temp": gpu["temp"],
                "power": gpu["power"],
                "power_cap": gpu["power_cap"],
                "vram_used": gpu["vram_used"],
                "vram_total": gpu["vram_total"],
                "vram_percent": gpu["vram_percent"],
                "gtt_used": gpu["gtt_used"],
                "gtt_total": gpu["gtt_total"],
                "sclk": gpu["sclk"],
                "mclk": gpu["mclk"],
                "fan": gpu["fan"],
                # Sur APU à mémoire unifiée (Strix Halo), la RAM système est la VRAM.
                "unified": bool(gpu["gtt_total"] and gpu["vram_total"]
                                and gpu["gtt_total"] >= gpu["vram_total"]),
                "cpu_model": (sample.get("meta") or {}).get("cpu_model"),
                "mem_total": sample.get("mem.total"),
            })
        del topic

    return {
        "endpoints": endpoints,
        "accelerators": accelerators,
        "summary": {
            "endpoints_online": len([e for e in endpoints if e["status"] == "online"]),
            "models_total": sum(len(e.get("models") or []) for e in endpoints),
            "models_loaded": sum(len(e.get("loaded") or []) for e in endpoints),
            "vram_loaded": sum(m.get("size_vram", 0) for e in endpoints for m in (e.get("loaded") or [])),
        },
    }


@router.get("/endpoints")
async def list_endpoints(user: dict = Depends(current_user)) -> list[dict]:
    rows = await fetch_all(f"SELECT {COLUMNS} FROM ai_endpoints a ORDER BY a.name")
    return [_decorate(row) for row in rows]


@router.post("/endpoints", status_code=status.HTTP_201_CREATED)
async def create_endpoint(payload: EndpointIn, user: dict = Depends(current_user)) -> dict:
    probe = client_for({"kind": payload.kind, "url": payload.url, "api_key": payload.api_key})
    try:
        snap = await probe.snapshot()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY,
                            f"Impossible de joindre {payload.url} : {exc}") from exc
    fields = payload.model_dump(exclude={"api_key"})
    endpoint_id = await execute(
        "INSERT INTO ai_endpoints (name, url, host_id, kind, enabled, status, meta, api_key_enc) "
        "VALUES (:name, :url, :host_id, :kind, :enabled, 'online', CAST(:meta AS jsonb), :key) "
        "RETURNING id",
        {**fields,
         "meta": json.dumps({"version": snap["version"], "models": len(snap["models"])}),
         "key": encrypt(payload.api_key)},
    )
    row = await fetch_one(f"SELECT {COLUMNS} FROM ai_endpoints a WHERE a.id = :id", {"id": endpoint_id})
    return _decorate(row)


@router.patch("/endpoints/{endpoint_id}")
async def update_endpoint(endpoint_id: int, payload: EndpointPatch,
                          user: dict = Depends(current_user)) -> dict:
    ep = await fetch_one("SELECT * FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})
    if not ep:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Endpoint IA introuvable")

    fields = payload.model_dump(exclude_unset=True)
    if not fields:
        return _decorate(await fetch_one(f"SELECT {COLUMNS} FROM ai_endpoints a WHERE a.id = :id",
                                         {"id": endpoint_id}))

    kind = fields.get("kind", ep["kind"])
    url = fields.get("url", ep["url"])
    key = fields["api_key"] if "api_key" in fields else decrypt(ep["api_key_enc"])

    # On ne rejoue le test de connexion que si l'un de ses paramètres bouge :
    # renommer un serveur momentanément éteint ne doit pas échouer.
    touched = {"url", "kind", "api_key"} & set(fields)
    online = ep["status"]
    if touched:
        try:
            snap = await client_for({"kind": kind, "url": url, "api_key": key}).snapshot()
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status.HTTP_502_BAD_GATEWAY,
                                f"Impossible de joindre {url} : {exc}") from exc
        online = "online"
        fields["meta"] = json.dumps({"version": snap["version"], "models": len(snap["models"])})

    assignments = [f"{column} = :{column}" for column in fields if column != "api_key"]
    params = {k: v for k, v in fields.items() if k != "api_key"}
    if "meta" in params:
        assignments[assignments.index("meta = :meta")] = "meta = CAST(:meta AS jsonb)"
    if "api_key" in fields:
        assignments.append("api_key_enc = :api_key_enc")
        params["api_key_enc"] = encrypt(fields["api_key"])
    if touched:
        assignments.append("status = :status")
        params["status"] = online

    await execute(f"UPDATE ai_endpoints SET {', '.join(assignments)} WHERE id = :id",
                  {**params, "id": endpoint_id})
    row = await fetch_one(f"SELECT {COLUMNS} FROM ai_endpoints a WHERE a.id = :id",
                          {"id": endpoint_id})
    return _decorate(row)


@router.delete("/endpoints/{endpoint_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_endpoint(endpoint_id: int, user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/endpoints/{endpoint_id}/models/{model:path}")
async def model_detail(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    try:
        return await client.show(model)
    except UnsupportedOperation as exc:
        raise HTTPException(status.HTTP_501_NOT_IMPLEMENTED, str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc


@router.delete("/endpoints/{endpoint_id}/models/{model:path}")
async def delete_model(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    try:
        await client.delete(model)
    except UnsupportedOperation as exc:
        raise HTTPException(status.HTTP_501_NOT_IMPLEMENTED, str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc
    return {"ok": True}


@router.post("/endpoints/{endpoint_id}/unload/{model:path}")
async def unload_model(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    try:
        await client.unload(model)
    except UnsupportedOperation as exc:
        raise HTTPException(status.HTTP_501_NOT_IMPLEMENTED, str(exc)) from exc
    return {"ok": True}


@router.post("/endpoints/{endpoint_id}/pull")
async def pull_model(endpoint_id: int, payload: PullIn, user: dict = Depends(current_user)):
    client = await _client(endpoint_id)

    async def stream():
        try:
            async for chunk in client.pull(payload.model):
                yield _sse(chunk)
        except UnsupportedOperation as exc:
            yield _sse({"error": str(exc)})
        except Exception as exc:  # noqa: BLE001
            yield _sse({"error": str(exc)[:300]})
        yield _sse({"done": True})

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.post("/endpoints/{endpoint_id}/chat")
async def chat(endpoint_id: int, payload: ChatIn, user: dict = Depends(current_user)):
    client = await _client(endpoint_id)
    options: dict[str, Any] = {}
    if payload.temperature is not None:
        options["temperature"] = payload.temperature
    if payload.num_ctx:
        options["num_ctx"] = payload.num_ctx

    async def stream():
        try:
            async for chunk in client.chat(payload.model, payload.messages, options or None):
                yield _sse(chunk)
        except Exception as exc:  # noqa: BLE001
            yield _sse({"error": str(exc)[:300]})
        yield _sse({"done": True})

    return StreamingResponse(stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


async def _client(endpoint_id: int, timeout: float = 20.0):
    ep = await fetch_one("SELECT * FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})
    if not ep:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Endpoint IA introuvable")
    return client_for(ep, timeout=timeout)
