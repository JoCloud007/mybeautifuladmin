"""Client Ollama : inventaire des modèles, modèles chargés, génération en flux."""
from __future__ import annotations

import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

log = logging.getLogger("mba.ollama")


class OllamaClient:
    def __init__(self, url: str, timeout: float = 20.0) -> None:
        self.url = url.rstrip("/")
        self.timeout = timeout

    def _client(self, timeout: float | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(base_url=self.url, timeout=timeout or self.timeout)

    async def snapshot(self) -> dict[str, Any]:
        async with self._client() as client:
            version, tags, ps = "", {}, {}
            try:
                version = (await client.get("/api/version")).json().get("version", "")
            except (httpx.HTTPError, ValueError):
                pass
            tags = (await client.get("/api/tags")).json()
            try:
                ps = (await client.get("/api/ps")).json()
            except (httpx.HTTPError, ValueError):
                ps = {}

        models = [{
            "name": m.get("name") or m.get("model"),
            "size": m.get("size", 0),
            "modified": m.get("modified_at"),
            "family": (m.get("details") or {}).get("family"),
            "parameters": (m.get("details") or {}).get("parameter_size"),
            "quantization": (m.get("details") or {}).get("quantization_level"),
            "digest": (m.get("digest") or "")[:12],
        } for m in (tags.get("models") or [])]

        loaded = [{
            "name": m.get("name") or m.get("model"),
            "size": m.get("size", 0),
            "size_vram": m.get("size_vram", 0),
            "expires_at": m.get("expires_at"),
            "context": (m.get("details") or {}).get("parameter_size"),
        } for m in (ps.get("models") or [])]

        return {
            "version": version,
            "models": sorted(models, key=lambda m: -(m["size"] or 0)),
            "loaded": loaded,
            "metrics": {
                "ollama.models": float(len(models)),
                "ollama.loaded": float(len(loaded)),
                "ollama.vram_used": float(sum(m["size_vram"] for m in loaded)),
                "ollama.disk_used": float(sum(m["size"] or 0 for m in models)),
            },
        }

    async def show(self, model: str) -> dict:
        async with self._client() as client:
            resp = await client.post("/api/show", json={"name": model})
            resp.raise_for_status()
            return resp.json()

    async def delete(self, model: str) -> None:
        async with self._client() as client:
            resp = await client.request("DELETE", "/api/delete", json={"name": model})
            resp.raise_for_status()

    async def unload(self, model: str) -> None:
        """keep_alive=0 décharge immédiatement le modèle de la VRAM."""
        async with self._client() as client:
            await client.post("/api/generate", json={"model": model, "keep_alive": 0})

    async def pull(self, model: str) -> AsyncIterator[dict]:
        async with self._client(timeout=None) as client:
            async with client.stream("POST", "/api/pull", json={"name": model, "stream": True}) as resp:
                async for line in resp.aiter_lines():
                    if line.strip():
                        try:
                            yield json.loads(line)
                        except json.JSONDecodeError:
                            continue

    async def chat(self, model: str, messages: list[dict], options: dict | None = None) -> AsyncIterator[dict]:
        payload = {"model": model, "messages": messages, "stream": True}
        if options:
            payload["options"] = options
        async with self._client(timeout=None) as client:
            async with client.stream("POST", "/api/chat", json=payload) as resp:
                if resp.status_code >= 400:
                    body = await resp.aread()
                    raise RuntimeError(body.decode("utf-8", "replace")[:300])
                async for line in resp.aiter_lines():
                    if line.strip():
                        try:
                            yield json.loads(line)
                        except json.JSONDecodeError:
                            continue
