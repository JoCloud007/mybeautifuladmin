"""Inventaire d'un tailnet Tailscale.

Deux sources possibles, selon ce dont on dispose :

* **API Tailscale** — clé d'API (`tskey-api-…`) + nom du tailnet. Vue complète et
  centralisée, y compris les machines que le conteneur ne peut pas joindre.
* **Client local** — `tailscale status --json` exécuté en SSH sur une machine du
  tailnet. Aucune clé à créer ; pratique quand MBA n'est pas lui-même sur le réseau.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
from typing import Any

import httpx

from ..ssh import SSHError, pool

log = logging.getLogger("mba.tailscale")

API_BASE = "https://api.tailscale.com/api/v2"
# Au-delà, une machine dont on n'a pas de nouvelles est considérée hors ligne.
OFFLINE_AFTER = dt.timedelta(minutes=5)

# Correspondance OS Tailscale → type d'hôte MBA.
OS_KIND = {
    "linux": "linux",
    "freebsd": "linux",
    "openbsd": "linux",
    "synology": "synology",
    "macOS": "generic",
    "windows": "generic",
    "iOS": "generic",
    "android": "generic",
    "tvOS": "generic",
}


class TailscaleError(RuntimeError):
    pass


def _parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _device(
    *,
    node_id: str,
    hostname: str,
    dns_name: str,
    addresses: list[str],
    os_name: str,
    version: str,
    tags: list[str],
    last_seen: dt.datetime | None,
    online: bool | None,
    user: str | None = None,
    update_available: bool = False,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    ipv4 = next((a for a in addresses if ":" not in a), addresses[0] if addresses else "")
    if online is None:
        online = bool(last_seen and dt.datetime.now(dt.timezone.utc) - last_seen < OFFLINE_AFTER)
    return {
        "tailscale_id": node_id,
        "hostname": hostname,
        "dns_name": dns_name.rstrip("."),
        "address": ipv4,
        "addresses": addresses,
        "os": os_name,
        "version": version,
        # Les tags ACL Tailscale arrivent préfixés « tag: », on les nettoie.
        "tags": [t.removeprefix("tag:") for t in tags],
        "online": online,
        "last_seen": last_seen.isoformat() if last_seen else None,
        "user": user,
        "update_available": update_available,
        "guessed_kind": OS_KIND.get(os_name, "generic"),
        **(extra or {}),
    }


# ------------------------------------------------------------------ API v2
async def devices_from_api(api_key: str, tailnet: str = "-") -> list[dict[str, Any]]:
    url = f"{API_BASE}/tailnet/{tailnet or '-'}/devices"
    async with httpx.AsyncClient(timeout=25.0) as client:
        resp = await client.get(url, params={"fields": "all"},
                                headers={"Authorization": f"Bearer {api_key}"})
    if resp.status_code == 401:
        raise TailscaleError("Clé d'API refusée (401) — vérifie qu'elle n'a pas expiré")
    if resp.status_code == 403:
        raise TailscaleError("Accès refusé (403) — la clé n'a pas le périmètre « devices:read »")
    if resp.status_code >= 400:
        raise TailscaleError(f"API Tailscale : {resp.status_code} {resp.text[:200]}")

    devices = []
    for d in resp.json().get("devices") or []:
        devices.append(_device(
            node_id=d.get("nodeId") or d.get("id", ""),
            hostname=d.get("hostname") or d.get("name", "").split(".")[0],
            dns_name=d.get("name", ""),
            addresses=d.get("addresses") or [],
            os_name=d.get("os", ""),
            version=(d.get("clientVersion") or "").split("-")[0],
            tags=d.get("tags") or [],
            last_seen=_parse_time(d.get("lastSeen")),
            online=None,
            user=d.get("user"),
            update_available=bool(d.get("updateAvailable")),
            extra={"expires": d.get("expires"), "ephemeral": bool(d.get("isExternal"))},
        ))
    return sorted(devices, key=lambda d: (not d["online"], d["hostname"]))


async def test_api(api_key: str, tailnet: str = "-") -> dict[str, Any]:
    devices = await devices_from_api(api_key, tailnet)
    return {"ok": True, "devices": len(devices),
            "online": len([d for d in devices if d["online"]])}


# ------------------------------------------------------- client local (SSH)
async def devices_from_host(host: dict) -> list[dict[str, Any]]:
    try:
        raw = await pool.run(host, "tailscale status --json 2>/dev/null", timeout=30)
    except SSHError as exc:
        raise TailscaleError(f"Lecture impossible sur {host['name']} : {exc}") from exc

    raw = raw.strip()
    if not raw.startswith("{"):
        raise TailscaleError(
            f"« tailscale » est introuvable sur {host['name']} "
            "(installe le client, ou utilise une clé d'API)"
        )
    try:
        status = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise TailscaleError("Sortie de « tailscale status » illisible") from exc

    nodes = dict(status.get("Peer") or {})
    if status.get("Self"):
        nodes["__self__"] = status["Self"]

    devices = []
    for node in nodes.values():
        dns_name = node.get("DNSName", "")
        devices.append(_device(
            node_id=node.get("ID", "") or node.get("PublicKey", "")[:16],
            hostname=node.get("HostName") or dns_name.split(".")[0],
            dns_name=dns_name,
            addresses=node.get("TailscaleIPs") or [],
            os_name=node.get("OS", ""),
            version=(node.get("ClientVersion") or "").split("-")[0],
            tags=node.get("Tags") or [],
            last_seen=_parse_time(node.get("LastSeen")),
            online=node.get("Online"),
            user=None,
            update_available=bool(node.get("UpdateAvailable")),
            extra={"exit_node": bool(node.get("ExitNode")),
                   "self": node is status.get("Self")},
        ))
    return sorted(devices, key=lambda d: (not d["online"], d["hostname"]))
