"""Vue réseau : ce qui existe, où, et depuis quand.

Les équipements viennent de trois origines — les hôtes supervisés, les résultats
de découverte, et les machines vues sur le tailnet. On les rassemble, on les
range par sous-réseau, étiquette ou emplacement, et on garde la trace des
apparitions et disparitions.
"""
from __future__ import annotations

import ipaddress
import re
from typing import Any

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel

from ..bus import bus
from ..db import fetch_all
from ..security import current_user

router = APIRouter(prefix="/network", tags=["réseau"])

# Ports usuels → service reconnaissable, pour qualifier un équipement.
PORT_ROLES: dict[int, str] = {
    22: "SSH", 80: "HTTP", 443: "HTTPS", 445: "SMB", 548: "AFP",
    2375: "Docker", 2376: "Docker TLS", 3306: "MySQL", 5432: "PostgreSQL",
    5000: "DSM", 5001: "DSM", 6379: "Redis", 8006: "Proxmox", 8007: "PBS",
    8123: "Home Assistant", 11434: "Ollama", 9090: "Cockpit", 32400: "Plex",
    1883: "MQTT", 623: "IPMI", 3389: "RDP", 5900: "VNC",
}

TAILSCALE_RE = re.compile(r"\.ts\.net$", re.I)


def _subnet_of(address: str) -> str:
    """Sous-réseau /24 d'une adresse, ou un libellé pour les cas particuliers."""
    if not address or address == "local":
        return "Local (socket)"
    if TAILSCALE_RE.search(address):
        return "Tailscale"
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return "Nom DNS"
    if isinstance(ip, ipaddress.IPv6Address):
        return "IPv6"
    if ip.is_loopback:
        return "Loopback"
    # 100.64.0.0/10 est la plage CGNAT utilisée par Tailscale.
    if ipaddress.ip_address("100.64.0.0") <= ip <= ipaddress.ip_address("100.127.255.255"):
        return "Tailscale"
    return str(ipaddress.ip_network(f"{address}/24", strict=False))


def _roles(ports: list[int]) -> list[str]:
    return sorted({PORT_ROLES[p] for p in (ports or []) if p in PORT_ROLES})


@router.get("")
async def overview(
    group_by: str = Query("subnet", pattern="^(subnet|tag|location|kind|category)$"),
    user: dict = Depends(current_user),
) -> dict:
    hosts = await fetch_all(
        "SELECT h.*, c.name AS credential_name FROM hosts h "
        "LEFT JOIN credentials c ON c.id = h.credential_id ORDER BY h.name"
    )
    discovered = await fetch_all(
        "SELECT * FROM discovery_results WHERE NOT ignored ORDER BY seen_at DESC"
    )
    live = bus.latest("metrics.")
    known_addresses = {h["address"] for h in hosts}

    assets: list[dict[str, Any]] = []

    for host in hosts:
        meta = host.get("meta") or {}
        sample = live.get(f"metrics.{host['id']}", {})
        ports = meta.get("listening_ports") or []
        assets.append({
            "kind": "host",
            "id": host["id"],
            "name": host["name"],
            "address": host["address"],
            "subnet": _subnet_of(host["address"]),
            "host_kind": host["kind"],
            "status": host["status"],
            "tags": host.get("tags") or [],
            "category": host.get("category"),
            "location": host.get("location"),
            "macs": meta.get("macs") or {},
            "os": meta.get("os"),
            "model": meta.get("model"),
            "ports": ports[:20],
            "roles": _roles(ports),
            "supervised": True,
            "first_seen": host.get("created_at"),
            "last_seen": host.get("last_seen"),
            "uptime": sample.get("uptime"),
            "tailscale": bool(host.get("tailscale_id"))
            or bool(TAILSCALE_RE.search(host["address"] or "")),
        })

    for entry in discovered:
        if entry["address"] in known_addresses:
            continue
        meta = entry.get("meta") or {}
        assets.append({
            "kind": "discovered",
            "id": None,
            "name": entry.get("hostname") or entry["address"],
            "address": entry["address"],
            "subnet": _subnet_of(entry["address"]),
            "host_kind": entry.get("guessed_kind"),
            "status": "unknown" if not meta.get("online") else "online",
            "tags": meta.get("tags") or [],
            "category": None,
            "location": None,
            "macs": {},
            "os": meta.get("os"),
            "model": None,
            "ports": entry.get("open_ports") or [],
            "roles": _roles(entry.get("open_ports") or []),
            "supervised": False,
            "first_seen": entry.get("seen_at"),
            "last_seen": entry.get("seen_at"),
            "tailscale": entry.get("source") == "tailscale",
        })

    # Regroupement demandé — un actif sans valeur tombe dans « non renseigné ».
    field = {"subnet": "subnet", "tag": "tags", "location": "location",
             "kind": "host_kind", "category": "category"}[group_by]
    groups: dict[str, list[dict]] = {}
    for asset in assets:
        value = asset.get(field)
        keys = value if isinstance(value, list) else [value]
        for key in (keys or [None]):
            groups.setdefault(key or "Non renseigné", []).append(asset)

    grouped = [
        {
            "key": key,
            "count": len(items),
            "online": len([a for a in items if a["status"] == "online"]),
            "supervised": len([a for a in items if a["supervised"]]),
            "assets": sorted(items, key=lambda a: (not a["supervised"], a["name"].lower())),
        }
        for key, items in groups.items()
    ]
    grouped.sort(key=lambda g: (g["key"] == "Non renseigné", -g["count"]))

    subnets = {}
    for asset in assets:
        subnets.setdefault(asset["subnet"], 0)
        subnets[asset["subnet"]] += 1

    return {
        "assets": assets,
        "groups": grouped,
        "group_by": group_by,
        "summary": {
            "total": len(assets),
            "supervised": len([a for a in assets if a["supervised"]]),
            "unmanaged": len([a for a in assets if not a["supervised"]]),
            "online": len([a for a in assets if a["status"] == "online"]),
            "subnets": len(subnets),
            "tailscale": len([a for a in assets if a["tailscale"]]),
            "by_subnet": subnets,
        },
    }


@router.get("/history")
async def history(days: int = Query(30, ge=1, le=365),
                  user: dict = Depends(current_user)) -> dict:
    """Apparitions, disparitions et changements d'état sur la période."""
    events = await fetch_all(
        """SELECT e.time, e.level, e.source, e.message, e.data, e.host_id, h.name AS host_name,
                  h.address
           FROM events e LEFT JOIN hosts h ON h.id = e.host_id
           WHERE e.time > now() - make_interval(days => :d)
             AND e.source IN ('collecte', 'poller', 'inventaire', 'ipmi', 'domotique')
           ORDER BY e.time DESC LIMIT 300""",
        {"d": days},
    )

    appeared = await fetch_all(
        "SELECT name, address, kind, created_at FROM hosts "
        "WHERE created_at > now() - make_interval(days => :d) ORDER BY created_at DESC",
        {"d": days},
    )
    discovered = await fetch_all(
        "SELECT address, hostname, guessed_kind, seen_at, adopted, source FROM discovery_results "
        "WHERE seen_at > now() - make_interval(days => :d) ORDER BY seen_at DESC LIMIT 100",
        {"d": days},
    )

    # Disponibilité par hôte sur la période, calculée sur les points de collecte.
    availability = await fetch_all(
        """SELECT h.id, h.name,
                  count(*) AS points,
                  min(m.time) AS first_point,
                  max(m.time) AS last_point
           FROM hosts h JOIN metrics m ON m.host_id = h.id
           WHERE m.time > now() - make_interval(days => :d) AND m.metric = 'cpu.usage'
           GROUP BY h.id, h.name ORDER BY h.name""",
        {"d": days},
    )

    return {
        "events": events,
        "appeared": appeared,
        "discovered": discovered,
        "availability": availability,
        "days": days,
    }
