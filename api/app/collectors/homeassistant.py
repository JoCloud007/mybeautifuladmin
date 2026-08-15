"""Client Home Assistant (API REST).

Authentification par jeton d'accès longue durée, généré depuis le profil
utilisateur de Home Assistant. On lit l'état des entités, on les regroupe par
domaine, et on peut appeler les services (allumer, éteindre, basculer).
"""
from __future__ import annotations

import datetime as dt
import logging
from typing import Any

import httpx

from ..db import fetch_one
from ..vault import decrypt

log = logging.getLogger("mba.hass")

# Domaines pilotables depuis MBA, avec le service de bascule associé.
CONTROLLABLE = {
    "light": "toggle",
    "switch": "toggle",
    "fan": "toggle",
    "input_boolean": "toggle",
    "automation": "toggle",
    "script": "turn_on",
    "scene": "turn_on",
    "media_player": "toggle",
    "cover": None,      # open/close, traité à part
    "climate": None,
}

DOMAIN_LABEL = {
    "light": "Éclairages",
    "switch": "Interrupteurs",
    "sensor": "Capteurs",
    "binary_sensor": "Capteurs binaires",
    "climate": "Chauffage / clim",
    "cover": "Volets",
    "media_player": "Lecteurs",
    "automation": "Automatisations",
    "script": "Scripts",
    "scene": "Scènes",
    "person": "Personnes",
    "device_tracker": "Présence",
    "camera": "Caméras",
    "lock": "Serrures",
    "vacuum": "Aspirateurs",
    "update": "Mises à jour",
    "sun": "Soleil",
    "weather": "Météo",
    "fan": "Ventilation",
    "input_boolean": "Bascules",
    "number": "Réglages",
    "select": "Sélecteurs",
    "button": "Boutons",
    "zone": "Zones",
}

UNAVAILABLE = ("unavailable", "unknown")


class HomeAssistantError(RuntimeError):
    pass


class HomeAssistantClient:
    def __init__(self, url: str, token: str) -> None:
        self.base = url.rstrip("/")
        self.token = token

    def _client(self, timeout: float = 20.0) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self.base,
            timeout=timeout,
            verify=False,
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"},
        )

    async def _get(self, client: httpx.AsyncClient, path: str) -> Any:
        resp = await client.get(path)
        if resp.status_code == 401:
            raise HomeAssistantError("Jeton refusé (401) — vérifie le jeton d'accès longue durée")
        if resp.status_code == 404:
            return None
        if resp.status_code >= 400:
            raise HomeAssistantError(f"{path} → {resp.status_code}")
        return resp.json()

    async def ping(self) -> dict[str, Any]:
        async with self._client(timeout=10.0) as client:
            try:
                root = await self._get(client, "/api/")
            except httpx.HTTPError as exc:
                raise HomeAssistantError(f"Injoignable : {exc}") from exc
            config = await self._get(client, "/api/config") or {}
        return {
            "message": (root or {}).get("message"),
            "version": config.get("version"),
            "location": config.get("location_name"),
            "timezone": config.get("time_zone"),
            "components": len(config.get("components") or []),
        }

    async def snapshot(self) -> dict[str, Any]:
        async with self._client() as client:
            config = await self._get(client, "/api/config") or {}
            states = await self._get(client, "/api/states") or []

        entities = []
        for state in states:
            entity_id = state.get("entity_id", "")
            domain = entity_id.split(".")[0] if "." in entity_id else "autre"
            attrs = state.get("attributes") or {}
            value = state.get("state")
            entities.append({
                "entity_id": entity_id,
                "domain": domain,
                "name": attrs.get("friendly_name") or entity_id,
                "state": value,
                "unit": attrs.get("unit_of_measurement"),
                "device_class": attrs.get("device_class"),
                "battery": attrs.get("battery_level"),
                "available": value not in UNAVAILABLE,
                "controllable": domain in CONTROLLABLE,
                "changed": state.get("last_changed"),
                "area": attrs.get("area") or attrs.get("area_id"),
                "icon": attrs.get("icon"),
            })

        by_domain: dict[str, int] = {}
        for entity in entities:
            by_domain[entity["domain"]] = by_domain.get(entity["domain"], 0) + 1

        unavailable = [e for e in entities if not e["available"]]
        low_battery = [
            e for e in entities
            if isinstance(e.get("battery"), (int, float)) and e["battery"] <= 20
        ]
        # Une entité « update » à « on » signale une mise à jour disponible.
        updates = [e for e in entities if e["domain"] == "update" and e["state"] == "on"]
        automations_off = [
            e for e in entities if e["domain"] == "automation" and e["state"] == "off"
        ]

        return {
            "version": config.get("version"),
            "location": config.get("location_name"),
            "entities": entities,
            "by_domain": by_domain,
            "metrics": {
                "hass.entities": float(len(entities)),
                "hass.unavailable": float(len(unavailable)),
                "hass.low_battery": float(len(low_battery)),
                "hass.updates": float(len(updates)),
            },
            "summary": {
                "entities": len(entities),
                "domains": len(by_domain),
                "unavailable": len(unavailable),
                "low_battery": len(low_battery),
                "updates": len(updates),
                "automations_off": len(automations_off),
                "lights_on": len([e for e in entities
                                  if e["domain"] == "light" and e["state"] == "on"]),
                "switches_on": len([e for e in entities
                                    if e["domain"] == "switch" and e["state"] == "on"]),
            },
        }

    async def call_service(self, domain: str, service: str, entity_id: str) -> Any:
        async with self._client(timeout=30.0) as client:
            resp = await client.post(f"/api/services/{domain}/{service}",
                                     json={"entity_id": entity_id})
        if resp.status_code >= 400:
            raise HomeAssistantError(f"{domain}.{service} → {resp.status_code} {resp.text[:180]}")
        return resp.json() if resp.content else []

    async def history(self, entity_id: str, hours: int = 24) -> list[dict]:
        start = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)).isoformat()
        async with self._client(timeout=30.0) as client:
            data = await self._get(
                client, f"/api/history/period/{start}?filter_entity_id={entity_id}"
            )
        series = (data or [[]])[0] if data else []
        points = []
        for entry in series:
            try:
                value = float(entry.get("state"))
            except (TypeError, ValueError):
                continue
            when = entry.get("last_changed") or entry.get("last_updated")
            points.append({"time": when, "value": value})
        return points

    async def error_log(self, lines: int = 80) -> str:
        async with self._client(timeout=20.0) as client:
            resp = await client.get("/api/error_log")
        if resp.status_code >= 400:
            return ""
        return "\n".join(resp.text.splitlines()[-lines:])


async def client_for_host(host: dict) -> HomeAssistantClient:
    cred_id = host.get("credential_id")
    if not cred_id:
        raise HomeAssistantError(f"Aucun jeton associé à « {host['name']} »")
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
    if not cred:
        raise HomeAssistantError("Identifiant introuvable")
    if cred["kind"] not in ("token", "api_token", "basic"):
        raise HomeAssistantError(
            f"L'identifiant « {cred['name'] } » est de type « {cred['kind']} ». "
            "Home Assistant attend un jeton : crée un identifiant de type « Jeton » "
            "et colle-y le jeton d'accès longue durée."
        )
    token = decrypt(cred["secret_enc"])
    if not token:
        raise HomeAssistantError(
            "Le secret est vide ou illisible. Si le coffre a été recréé, ressaisis le jeton."
        )
    if token.count(".") != 2:
        raise HomeAssistantError(
            "Ce secret ne ressemble pas à un jeton Home Assistant (JWT en trois parties). "
            "Profil → Sécurité → « Créer un jeton », puis colle la valeur complète."
        )

    meta = host.get("meta") or {}
    scheme = "https" if meta.get("secure") else "http"
    port = host.get("port") or 8123
    url = meta.get("url") or f"{scheme}://{host['address']}:{port}"
    return HomeAssistantClient(url, token)
