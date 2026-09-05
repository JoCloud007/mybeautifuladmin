"""Choix du client d'inférence selon le type d'endpoint.

Deux dialectes aujourd'hui : Ollama, qui gère aussi le cycle de vie des modèles,
et l'API OpenAI (vLLM, TGI, LM Studio, llama.cpp, passerelles), qui ne sait que
servir ce qu'on lui a donné. Le reste du code passe par `client_for` et
`capabilities` plutôt que d'instancier un client en dur.
"""
from __future__ import annotations

from typing import Any

from ..vault import decrypt
from .ollama import OllamaClient
from .openai_api import OpenAICompatClient, UnsupportedOperation

__all__ = ["KINDS", "UnsupportedOperation", "capabilities", "client_for", "normalize_kind"]

KINDS: dict[str, dict[str, Any]] = {
    "ollama": {
        "label": "Ollama",
        # Gestes proposés par l'interface pour ce type d'endpoint.
        "capabilities": ["chat", "pull", "delete", "unload"],
        "needs_key": False,
    },
    "openai": {
        "label": "vLLM / API OpenAI",
        "capabilities": ["chat"],
        "needs_key": False,  # vLLM tourne souvent sans clé sur un réseau privé
    },
}

# Ce que l'utilisateur peut écrire → le type réellement stocké.
_ALIASES = {"vllm": "openai", "openai-compatible": "openai", "open-ai": "openai"}


def normalize_kind(kind: str | None) -> str:
    value = (kind or "ollama").strip().lower()
    value = _ALIASES.get(value, value)
    if value not in KINDS:
        raise ValueError(f"Type d'endpoint inconnu : {kind}")
    return value


def capabilities(kind: str | None) -> list[str]:
    try:
        return list(KINDS[normalize_kind(kind)]["capabilities"])
    except ValueError:
        return list(KINDS["ollama"]["capabilities"])


def client_for(endpoint: dict, timeout: float = 20.0) -> OllamaClient | OpenAICompatClient:
    """Client prêt à l'emploi pour une ligne de `ai_endpoints`."""
    kind = normalize_kind(endpoint.get("kind"))
    if kind == "openai":
        key = endpoint.get("api_key") or decrypt(endpoint.get("api_key_enc"))
        return OpenAICompatClient(endpoint["url"], api_key=key, timeout=timeout)
    return OllamaClient(endpoint["url"], timeout=timeout)
