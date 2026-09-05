"""Client pour serveurs compatibles API OpenAI : vLLM, TGI, LM Studio, llama.cpp…

Le vocabulaire d'Ollama sert de langue commune côté MBA : ce client parle donc
`/v1/*` en sortie mais rend des instantanés et des morceaux de dialogue à la
forme d'Ollama, pour que le poller, les agents, le web et l'app iOS n'aient
qu'un seul format à connaître.
"""
from __future__ import annotations

import json
import logging
import time
from collections.abc import AsyncIterator
from typing import Any

import httpx

log = logging.getLogger("mba.openai")


class UnsupportedOperation(RuntimeError):
    """Geste qui n'existe pas côté API OpenAI (télécharger, effacer, décharger)."""


class OpenAICompatClient:
    kind = "openai"

    def __init__(self, url: str, api_key: str | None = None, timeout: float = 20.0) -> None:
        base = url.rstrip("/")
        # L'URL peut être donnée avec ou sans /v1 : vLLM sert les deux formes,
        # on normalise pour ne pas dépendre de ce que l'utilisateur a collé.
        self.root = base[: -len("/v1")] if base.endswith("/v1") else base
        self.url = f"{self.root}/v1"
        self.api_key = api_key or None
        self.timeout = timeout

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {}

    def _client(self, timeout: float | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(base_url=self.url, timeout=timeout or self.timeout,
                                 headers=self._headers())

    async def snapshot(self) -> dict[str, Any]:
        async with self._client() as client:
            resp = await client.get("/models")
            if resp.status_code in (401, 403):
                raise RuntimeError("Authentification refusée : clé d'API absente ou invalide")
            resp.raise_for_status()
            catalog = resp.json()
            version = ""
            try:
                # Propre à vLLM, et servi à la racine plutôt que sous /v1.
                version = (await client.get(f"{self.root}/version")).json().get("version", "")
            except (httpx.HTTPError, ValueError):
                pass

        models, loaded = [], []
        for entry in catalog.get("data") or []:
            name = entry.get("id") or ""
            if not name:
                continue
            context = entry.get("max_model_len")
            models.append({
                "name": name,
                # L'API OpenAI ne publie ni le poids sur disque ni la
                # quantization : on laisse les champs vides plutôt que d'inventer.
                "size": 0,
                "modified": _iso(entry.get("created")),
                "family": entry.get("owned_by"),
                "parameters": f"{context} ctx" if context else None,
                "quantization": None,
                "digest": "",
            })
            # `max_model_len` n'existe que chez vLLM, et vLLM ne publie que le
            # ou les modèles qu'il sert — donc résidents en mémoire. Une
            # passerelle générique (LiteLLM, OpenAI) liste un catalogue :
            # rien n'y est chargé localement, on ne prétend pas le contraire.
            if context:
                loaded.append({
                    "name": name,
                    "size": 0,
                    "size_vram": 0,
                    "expires_at": None,
                    "context": f"{context} ctx",
                })

        return {
            "version": version,
            "models": sorted(models, key=lambda m: m["name"]),
            "loaded": loaded,
            "metrics": {
                "ai.models": float(len(models)),
                "ai.loaded": float(len(loaded)),
            },
        }

    async def show(self, model: str) -> dict:
        async with self._client() as client:
            resp = await client.get("/models")
            resp.raise_for_status()
            for entry in resp.json().get("data") or []:
                if entry.get("id") == model:
                    return {"details": entry, "modelfile": None, "parameters": None}
        raise RuntimeError(f"Modèle « {model} » inconnu de ce serveur")

    async def delete(self, model: str) -> None:
        raise UnsupportedOperation(
            "Une API compatible OpenAI ne gère pas ses modèles : le modèle se choisit "
            "au lancement du serveur (vLLM) ou côté fournisseur."
        )

    async def unload(self, model: str) -> None:
        raise UnsupportedOperation(
            "Le déchargement mémoire n'existe pas côté API OpenAI : vLLM garde son "
            "modèle résident tant qu'il tourne."
        )

    async def pull(self, model: str) -> AsyncIterator[dict]:
        raise UnsupportedOperation(
            "Le téléchargement de modèles n'existe pas côté API OpenAI : le poids est "
            "servi par le serveur d'inférence lui-même."
        )
        yield {}  # pragma: no cover - garde la signature d'un générateur

    async def chat(self, model: str, messages: list[dict],
                   options: dict | None = None) -> AsyncIterator[dict]:
        payload: dict[str, Any] = {
            "model": model,
            "messages": messages,
            "stream": True,
            # Sans cela, vLLM et OpenAI omettent l'usage sur un flux : plus de
            # compteur de jetons ni de tok/s à afficher.
            "stream_options": {"include_usage": True},
        }
        if options and options.get("temperature") is not None:
            payload["temperature"] = options["temperature"]
        if options and options.get("max_tokens"):
            payload["max_tokens"] = options["max_tokens"]

        started = time.perf_counter()
        first_token_at: float | None = None
        usage: dict[str, Any] = {}
        finish_reason: str | None = None

        async with self._client(timeout=None) as client:
            async with client.stream("POST", "/chat/completions", json=payload) as resp:
                if resp.status_code >= 400:
                    body = await resp.aread()
                    raise RuntimeError(_error_text(body))
                async for line in resp.aiter_lines():
                    line = line.strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[len("data:"):].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    if chunk.get("usage"):
                        usage = chunk["usage"]
                    for choice in chunk.get("choices") or []:
                        finish_reason = choice.get("finish_reason") or finish_reason
                        content = (choice.get("delta") or {}).get("content")
                        if content:
                            if first_token_at is None:
                                first_token_at = time.perf_counter()
                            yield {"model": model, "done": False,
                                   "message": {"role": "assistant", "content": content}}

        total = time.perf_counter() - started
        generation = total - ((first_token_at or started) - started)
        yield {
            "model": model,
            "done": True,
            "done_reason": finish_reason or "stop",
            "message": {"role": "assistant", "content": ""},
            "eval_count": usage.get("completion_tokens"),
            "prompt_eval_count": usage.get("prompt_tokens"),
            # En nanosecondes : c'est l'unité d'Ollama, que web et iOS savent lire.
            "eval_duration": int(generation * 1e9),
            "total_duration": int(total * 1e9),
        }


def _iso(created: Any) -> str | None:
    """`created` est un horodatage Unix chez OpenAI, absent ailleurs."""
    if not isinstance(created, (int, float)) or created <= 0:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(created))


def _error_text(body: bytes) -> str:
    text = body.decode("utf-8", "replace")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return text[:300]
    error = payload.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or error)[:300]
    return str(error or payload.get("message") or text)[:300]
