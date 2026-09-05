"""Client de l'API publique OVHcloud.

Le stockage objet d'OVH s'interroge par l'API du fournisseur, jamais par l'API
S3 : un datastore PBS adossé à un bucket y range chaque chunk comme un objet, si
bien qu'un inventaire exhaustif d'un datastore de quelques téraoctets réclame
des milliers de requêtes `ListObjectsV2` — toutes facturées. OVH publie déjà la
volumétrie et le nombre d'objets par bucket, et la consommation valorisée du
projet : c'est gratuit, et suffisant pour surveiller un usage.

L'authentification est celle de l'API v1 : trois secrets (clé d'application, clé
secrète, clé de consommateur) et une signature SHA-1 de la requête, créés en une
fois sur https://api.ovh.com/createToken/.
"""
from __future__ import annotations

import hashlib
import json as jsonlib
import logging
import time
from typing import Any

import httpx

from ..db import fetch_one
from ..vault import decrypt

log = logging.getLogger("mba.ovh")

# Une clé d'API n'est valable que sur l'endpoint où elle a été créée.
ENDPOINTS: dict[str, str] = {
    "ovh-eu": "https://eu.api.ovh.com/1.0",
    "ovh-ca": "https://ca.api.ovh.com/1.0",
    "ovh-us": "https://api.us.ovhcloud.com/1.0",
    "kimsufi-eu": "https://eu.api.kimsufi.com/1.0",
    "soyoustart-eu": "https://eu.api.soyoustart.com/1.0",
}

# Unités renvoyées par l'API de consommation, en octets.
UNITS: dict[str, float] = {
    "b": 1, "o": 1, "byte": 1, "bytes": 1,
    "kb": 1000**1, "mb": 1000**2, "gb": 1000**3, "tb": 1000**4, "pb": 1000**5,
    "kib": 1024**1, "mib": 1024**2, "gib": 1024**3, "tib": 1024**4, "pib": 1024**5,
}


class OVHError(RuntimeError):
    """Erreur d'appel à l'API OVH, porteuse d'une piste de résolution."""

    def __init__(self, message: str, hint: str | None = None) -> None:
        super().__init__(message)
        self.hint = hint


def to_bytes(value: Any, unit: str | None) -> float | None:
    """Convertit une quantité OVH en octets.

    Les quantités horaires (« GiBh ») intègrent une durée : elles chiffrent une
    consommation cumulée, pas un encours, et ne disent donc rien de la taille
    actuelle d'un bucket. On les écarte plutôt que de les confondre avec elle.
    """
    if not isinstance(value, (int, float)) or unit is None:
        return None
    key = str(unit).strip().lower()
    if key.endswith("h") and key not in UNITS:  # GiBh, GBh… : cumul horaire
        return None
    factor = UNITS.get(key)
    return float(value) * factor if factor else None


class OVHClient:
    def __init__(self, endpoint: str, app_key: str, app_secret: str, consumer_key: str) -> None:
        self.base = ENDPOINTS.get(endpoint) or ENDPOINTS["ovh-eu"]
        self.app_key = app_key
        self.app_secret = app_secret
        self.consumer_key = consumer_key
        self._drift: float | None = None
        self._client = httpx.AsyncClient(timeout=30.0)

    # ------------------------------------------------------------- signature
    async def _timestamp(self) -> int:
        """Horodatage aligné sur l'API : au-delà de ~30 s d'écart, elle refuse."""
        if self._drift is None:
            try:
                resp = await self._client.get(f"{self.base}/auth/time")
                self._drift = float(resp.text.strip()) - time.time()
            except Exception:  # noqa: BLE001 — pas de réseau : on tente l'heure locale
                self._drift = 0.0
        return int(time.time() + self._drift)

    async def request(self, method: str, path: str, body: Any = None) -> Any:
        url = f"{self.base}{path}"
        payload = jsonlib.dumps(body, separators=(",", ":")) if body is not None else ""
        timestamp = await self._timestamp()
        raw = f"{self.app_secret}+{self.consumer_key}+{method}+{url}+{payload}+{timestamp}"
        headers = {
            "X-Ovh-Application": self.app_key,
            "X-Ovh-Consumer": self.consumer_key,
            "X-Ovh-Timestamp": str(timestamp),
            "X-Ovh-Signature": "$1$" + hashlib.sha1(raw.encode()).hexdigest(),
            "Content-Type": "application/json",
        }

        try:
            resp = await self._client.request(method, url, headers=headers,
                                              content=payload or None)
        except httpx.HTTPError as exc:
            raise OVHError(f"API OVH injoignable : {exc}") from exc

        if resp.status_code == 403:
            # OVH répond 403 aussi bien pour un droit manquant que pour une clé
            # invalide ou expirée : le message distingue les deux, pas le code.
            detail = _message(resp)
            granted = any(word in detail.lower() for word in ("grant", "authorization", "allowed"))
            raise OVHError(
                f"Accès refusé sur {path} — {detail}",
                "La clé d'API ne couvre pas ce chemin. Recrée-la sur "
                "api.ovh.com/createToken/ avec GET sur /cloud/* (ou /* pour tout)."
                if granted else
                "Vérifie les trois clés et l'endpoint : une clé d'application ou de "
                "consommateur invalide, révoquée ou expirée donne la même réponse.",
            )
        if resp.status_code == 401:
            raise OVHError(
                f"Authentification OVH refusée — {_message(resp)}",
                "Vérifie la clé d'application, la clé secrète, la clé de consommateur, "
                "et que l'endpoint choisi est bien celui où le jeton a été créé.",
            )
        if resp.status_code == 404:
            raise OVHError(f"{path} introuvable — {_message(resp)}")
        if resp.status_code >= 400:
            raise OVHError(f"{method} {path} → {resp.status_code} {_message(resp)}")
        if not resp.content:
            return None
        return resp.json()

    async def get(self, path: str) -> Any:
        return await self.request("GET", path)

    async def close(self) -> None:
        await self._client.aclose()

    # --------------------------------------------------------------- lecture
    async def me(self) -> dict:
        return await self.get("/me") or {}

    async def projects(self) -> list[dict]:
        """Projets Public Cloud accessibles, avec leur nom lisible."""
        ids = await self.get("/cloud/project") or []
        out = []
        for project_id in ids:
            try:
                detail = await self.get(f"/cloud/project/{project_id}") or {}
            except OVHError:
                detail = {}
            out.append({
                "id": project_id,
                "name": detail.get("description") or project_id,
                "status": detail.get("status"),
                "plan": (detail.get("planCode") or ""),
            })
        return out

    async def regions(self, project: str) -> list[str]:
        return await self.get(f"/cloud/project/{project}/region") or []

    async def buckets(self, project: str, region: str) -> list[dict]:
        """Buckets S3 d'une région (« Object Storage » compatible S3).

        Les régions sans stockage objet répondent 404 ou une liste vide : ce
        n'est pas une erreur, seulement une région à ne plus interroger.
        """
        raw = await self.get(f"/cloud/project/{project}/region/{region}/storage") or []
        return [_bucket(entry, region) for entry in raw if isinstance(entry, dict)]

    async def swift_containers(self, project: str) -> list[dict]:
        """Conteneurs Swift (offre historique), au cas où le projet en garde."""
        raw = await self.get(f"/cloud/project/{project}/storage") or []
        out = []
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            out.append({
                "kind": "container",
                "ext_id": f"swift/{entry.get('region')}/{entry.get('name') or entry.get('id')}",
                "name": entry.get("name") or entry.get("id"),
                "region": entry.get("region"),
                "status": "active",
                "size_bytes": _first_number(entry, "storedBytes", "objectsSize", "size"),
                "objects": _first_number(entry, "storedObjects", "objectsCount", "objects"),
                "meta": {"protocol": "swift", "public": entry.get("public"),
                         "static_url": entry.get("staticUrl")},
            })
        return out

    async def instances(self, project: str) -> list[dict]:
        raw = await self.get(f"/cloud/project/{project}/instance") or []
        out = []
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            flavor = entry.get("flavor") or {}
            ips = [ip.get("ip") for ip in (entry.get("ipAddresses") or []) if ip.get("ip")]
            out.append({
                "kind": "instance",
                "ext_id": f"instance/{entry.get('id')}",
                "name": entry.get("name") or entry.get("id"),
                "region": entry.get("region"),
                "status": (entry.get("status") or "").lower(),
                "meta": {
                    "flavor": flavor.get("name"),
                    "vcpus": flavor.get("vcpus"),
                    "ram_mb": flavor.get("ram"),
                    "disk_gb": flavor.get("disk"),
                    "image": (entry.get("image") or {}).get("name"),
                    "addresses": ips,
                    "created": entry.get("created"),
                },
            })
        return out

    async def volumes(self, project: str) -> list[dict]:
        raw = await self.get(f"/cloud/project/{project}/volume") or []
        out = []
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            size_gb = entry.get("size")
            out.append({
                "kind": "volume",
                "ext_id": f"volume/{entry.get('id')}",
                "name": entry.get("name") or entry.get("id"),
                "region": entry.get("region"),
                "status": (entry.get("status") or "").lower(),
                "size_bytes": float(size_gb) * 1024**3 if isinstance(size_gb, (int, float)) else None,
                "meta": {"type": entry.get("type"), "bootable": entry.get("bootable"),
                         "attached_to": entry.get("attachedTo") or []},
            })
        return out

    async def usage_current(self, project: str) -> dict:
        return await self.get(f"/cloud/project/{project}/usage/current") or {}

    async def usage_forecast(self, project: str) -> dict:
        return await self.get(f"/cloud/project/{project}/usage/forecast") or {}

    # -------------------------------------------------------------- synthèse
    async def snapshot(self, project: str, regions: list[str] | None = None) -> dict[str, Any]:
        """Vue complète d'un projet : ressources, coûts, régions utiles.

        `regions` restreint le balayage aux régions où du stockage a déjà été
        vu ; sans lui, on passe sur toutes celles du projet — une trentaine
        d'appels gratuits, qu'on ne refait qu'une fois par jour.
        """
        scanned = regions if regions is not None else await self.regions(project)
        resources: list[dict] = []
        storage_regions: list[str] = []
        errors: list[str] = []
        # Les catégories relevées sans erreur : elles seules autorisent à
        # conclure qu'une ressource absente de la réponse a bien disparu.
        collected: set[str] = {"bucket"}

        for region in scanned:
            try:
                found = await self.buckets(project, region)
            except OVHError as exc:
                log.debug("Pas de stockage objet en %s : %s", region, exc)
                continue
            if found:
                storage_regions.append(region)
                resources.extend(found)

        for kind, label, getter in (("container", "conteneurs Swift", self.swift_containers),
                                    ("instance", "instances", self.instances),
                                    ("volume", "volumes", self.volumes)):
            try:
                resources.extend(await getter(project))
                collected.add(kind)
            except OVHError as exc:
                errors.append(f"{label} : {exc}")

        try:
            usage = await self.usage_current(project)
        except OVHError as exc:
            usage, errors = {}, errors + [f"consommation : {exc}"]
        try:
            forecast = await self.usage_forecast(project)
        except OVHError as exc:
            forecast, errors = {}, errors + [f"prévision : {exc}"]

        costs = _costs(usage)
        _apply_costs(resources, costs)

        return {
            "resources": resources,
            "collected_kinds": sorted(collected),
            "storage_regions": storage_regions,
            "scanned_regions": scanned,
            "cost": {
                "current": _total(usage),
                "forecast": _total(forecast),
                "currency": _currency(usage) or _currency(forecast) or "EUR",
                "period_from": (usage.get("period") or {}).get("from"),
                "period_to": (usage.get("period") or {}).get("to"),
                "updated": usage.get("lastUpdate"),
                "by_bucket": costs,
            },
            "errors": errors,
        }


# ------------------------------------------------------------------ parsing
def _message(resp: httpx.Response) -> str:
    try:
        body = resp.json()
        if isinstance(body, dict):
            return str(body.get("message") or body.get("class") or resp.text[:160])
    except Exception:  # noqa: BLE001
        pass
    return resp.text[:160] or f"HTTP {resp.status_code}"


def _first_number(entry: dict, *keys: str) -> float | None:
    """Première clé présente et numérique — les noms varient selon l'offre."""
    for key in keys:
        value = entry.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return None


def _bucket(entry: dict, region: str) -> dict:
    name = entry.get("name") or entry.get("id")
    return {
        "kind": "bucket",
        "ext_id": f"s3/{region}/{name}",
        "name": name,
        "region": entry.get("region") or region,
        "status": "active",
        "size_bytes": _first_number(entry, "objectsSize", "storedBytes", "size"),
        "objects": _first_number(entry, "objectsCount", "storedObjects", "objects"),
        "meta": {
            "protocol": "s3",
            "created": entry.get("createdAt") or entry.get("created"),
            "owner": entry.get("ownerId"),
            "virtual_host": entry.get("virtualHost"),
            "encryption": (entry.get("encryption") or {}).get("sseAlgorithm")
            if isinstance(entry.get("encryption"), dict) else entry.get("encryption"),
            "versioning": (entry.get("versioning") or {}).get("status")
            if isinstance(entry.get("versioning"), dict) else entry.get("versioning"),
            # La réponse brute reste consultable : l'offre évolue plus vite que
            # ce parseur, et une clé inattendue ne doit pas être perdue.
            "raw": {k: v for k, v in entry.items() if k not in ("name", "id", "region")},
        },
    }


def _entries(usage: dict, section: str) -> list[dict]:
    """Lignes de consommation d'une catégorie, horaire puis mensuelle."""
    out: list[dict] = []
    for scope in ("hourlyUsage", "monthlyUsage"):
        block = usage.get(scope)
        if isinstance(block, dict):
            found = block.get(section)
            if isinstance(found, list):
                out.extend([e for e in found if isinstance(e, dict)])
    return out


def _price(entry: Any) -> float:
    """Prix total d'une ligne, quelle que soit la profondeur où OVH le range."""
    if not isinstance(entry, dict):
        return 0.0
    for key in ("totalPrice", "price"):
        value = entry.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, dict) and isinstance(value.get("value"), (int, float)):
            return float(value["value"])
    return 0.0


def _costs(usage: dict) -> dict[str, dict]:
    """Coût courant par bucket, agrégé sur toutes les lignes de stockage."""
    out: dict[str, dict] = {}
    for entry in _entries(usage, "storage"):
        name = entry.get("bucketName") or entry.get("name") or entry.get("id")
        if not name:
            continue
        region = entry.get("region")
        key = f"{region}/{name}" if region else str(name)
        slot = out.setdefault(key, {"name": name, "region": region, "price": 0.0,
                                    "stored": 0.0, "bandwidth_in": 0.0, "bandwidth_out": 0.0})
        stored = entry.get("stored") if isinstance(entry.get("stored"), dict) else {}
        quantity = stored.get("quantity") if isinstance(stored.get("quantity"), dict) else {}
        exact = to_bytes(quantity.get("value"), quantity.get("unit"))
        if exact:
            slot["stored"] = max(slot["stored"], exact)
        slot["price"] += _price(stored) or _price(entry)
        slot["price"] += _price(entry.get("incomingBandwidth")) + _price(entry.get("outgoingBandwidth"))
        for field, target in (("incomingBandwidth", "bandwidth_in"),
                              ("outgoingBandwidth", "bandwidth_out")):
            block = entry.get(field)
            if isinstance(block, dict):
                quantity = block.get("quantity") if isinstance(block.get("quantity"), dict) else {}
                slot[target] += to_bytes(quantity.get("value"), quantity.get("unit")) or 0.0
    return out


def _apply_costs(resources: list[dict], costs: dict[str, dict]) -> None:
    """Rapproche les lignes de facturation des buckets relevés."""
    by_name: dict[str, dict] = {}
    for key, entry in costs.items():
        by_name.setdefault(str(entry["name"]), entry)
        by_name[key] = entry

    for resource in resources:
        if resource["kind"] not in ("bucket", "container"):
            continue
        match = by_name.get(f"{resource.get('region')}/{resource['name']}") or by_name.get(resource["name"])
        if not match:
            continue
        resource["price_month"] = round(match["price"], 4)
        resource["meta"] = {**resource.get("meta", {}),
                            "bandwidth_in": match["bandwidth_in"],
                            "bandwidth_out": match["bandwidth_out"]}
        # Volumétrie de secours quand l'API des buckets n'a rien donné.
        if not resource.get("size_bytes") and match["stored"]:
            resource["size_bytes"] = match["stored"]
            resource["meta"]["size_from_billing"] = True


def _total(usage: dict) -> float | None:
    for key in ("total", "totalPrice"):
        value = usage.get(key)
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, dict) and isinstance(value.get("value"), (int, float)):
            return float(value["value"])
    hourly = usage.get("hourlyUsage")
    monthly = usage.get("monthlyUsage")
    parts = [b.get("total") for b in (hourly, monthly) if isinstance(b, dict)]
    numbers = [float(p) for p in parts if isinstance(p, (int, float))]
    return sum(numbers) if numbers else None


def _currency(usage: dict) -> str | None:
    for block in (usage.get("total"), usage.get("totalPrice")):
        if isinstance(block, dict) and block.get("currencyCode"):
            return str(block["currencyCode"])
    return None


# ------------------------------------------------------------- construction
async def client_for_credential(credential_id: int, endpoint: str = "ovh-eu") -> OVHClient:
    """Instancie un client depuis un identifiant du coffre.

    Les trois secrets OVH tiennent dans les champs existants : utilisateur =
    clé d'application, secret = clé secrète, phrase de passe = clé de
    consommateur.
    """
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": credential_id})
    if not cred:
        raise OVHError("Identifiants OVH introuvables")
    app_secret = decrypt(cred["secret_enc"]) or ""
    consumer = decrypt(cred["passphrase_enc"]) or ""
    app_key = cred["username"] or ""
    if not (app_key and app_secret and consumer):
        raise OVHError(
            "Identifiants OVH incomplets",
            "Il faut les trois clés : application (utilisateur), secrète (secret) "
            "et consommateur (phrase de passe).",
        )
    return OVHClient(endpoint, app_key, app_secret, consumer)
