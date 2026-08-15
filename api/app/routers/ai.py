from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Response, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from ..bus import bus
from ..collectors.ollama import OllamaClient
from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/ai", tags=["ai"])


class EndpointIn(BaseModel):
    name: str
    url: str
    host_id: int | None = None
    kind: str = "ollama"
    enabled: bool = True


class ChatIn(BaseModel):
    model: str
    messages: list[dict[str, str]]
    temperature: float | None = Field(default=None, ge=0, le=2)
    num_ctx: int | None = None


class PullIn(BaseModel):
    model: str = Field(min_length=1)


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, default=str)}\n\n"


@router.get("/overview")
async def overview(user: dict = Depends(current_user)) -> dict:
    endpoints = await fetch_all(
        "SELECT a.*, h.name AS host_name FROM ai_endpoints a "
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
    return await fetch_all("SELECT * FROM ai_endpoints ORDER BY name")


@router.post("/endpoints", status_code=status.HTTP_201_CREATED)
async def create_endpoint(payload: EndpointIn, user: dict = Depends(current_user)) -> dict:
    try:
        snap = await OllamaClient(payload.url).snapshot()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY,
                            f"Impossible de joindre {payload.url} : {exc}") from exc
    endpoint_id = await execute(
        "INSERT INTO ai_endpoints (name, url, host_id, kind, enabled, status, meta) "
        "VALUES (:name, :url, :host_id, :kind, :enabled, 'online', CAST(:meta AS jsonb)) RETURNING id",
        {**payload.model_dump(), "meta": json.dumps({"version": snap["version"]})},
    )
    return await fetch_one("SELECT * FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})


@router.delete("/endpoints/{endpoint_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_endpoint(endpoint_id: int, user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/endpoints/{endpoint_id}/models/{model:path}")
async def model_detail(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    try:
        return await client.show(model)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc


@router.delete("/endpoints/{endpoint_id}/models/{model:path}")
async def delete_model(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    try:
        await client.delete(model)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc
    return {"ok": True}


@router.post("/endpoints/{endpoint_id}/unload/{model:path}")
async def unload_model(endpoint_id: int, model: str, user: dict = Depends(current_user)) -> dict:
    client = await _client(endpoint_id)
    await client.unload(model)
    return {"ok": True}


@router.post("/endpoints/{endpoint_id}/pull")
async def pull_model(endpoint_id: int, payload: PullIn, user: dict = Depends(current_user)):
    client = await _client(endpoint_id)

    async def stream():
        try:
            async for chunk in client.pull(payload.model):
                yield _sse(chunk)
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


async def _client(endpoint_id: int) -> OllamaClient:
    ep = await fetch_one("SELECT * FROM ai_endpoints WHERE id = :id", {"id": endpoint_id})
    if not ep:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Endpoint IA introuvable")
    return OllamaClient(ep["url"])
