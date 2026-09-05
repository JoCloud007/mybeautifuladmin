"""Infrastructures de cloud public : synchronisation, historique, corrélation.

Un compte représente un projet chez un fournisseur ; ses ressources (buckets,
conteneurs, instances, volumes) sont relevées à intervalle régulier par l'API du
fournisseur, jamais par l'API S3 — voir `collectors/ovh.py` pour le pourquoi.

Le stockage objet mérite un traitement particulier : quand un bucket sert de
backend à un datastore Proxmox Backup Server, la volumétrie qu'on y surveille
n'est pas un chiffre de facturation, c'est la santé d'une sauvegarde. On va donc
lire la configuration des PBS supervisés pour rapprocher chaque bucket de son
datastore.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import time
from typing import Any

from . import notify
from .bus import bus
from .collectors import ovh as ovh_col
from .collectors import pbs as pbs_col
from .db import execute, execute_many, fetch_all, fetch_one
from .poller import log_event

log = logging.getLogger("mba.cloud")

# Cadence minimale du réveil ; chaque compte porte ensuite son propre intervalle.
TICK_SECONDS = 60
# Le balayage complet des régions n'a d'intérêt qu'une fois par jour : entre
# deux, on n'interroge que celles où un stockage a déjà été vu.
REGION_RESCAN_SECONDS = 86400

BUCKET_KINDS = ("bucket", "container")

# « type=s3,client=ovh-gra,bucket=pbs-backup » dans la configuration d'un datastore.
BUCKET_RE = re.compile(r"bucket[=:]\s*([A-Za-z0-9][A-Za-z0-9._-]{1,62})")


class CloudError(RuntimeError):
    def __init__(self, message: str, hint: str | None = None) -> None:
        super().__init__(message)
        self.hint = hint


# --------------------------------------------------------------- client
async def client_for_account(account: dict) -> ovh_col.OVHClient:
    if account["provider"] != "ovh":
        raise CloudError(f"Fournisseur « {account['provider']} » non pris en charge")
    if not account.get("credential_id"):
        raise CloudError(
            "Aucun identifiant associé à ce compte",
            "Réglages → Identifiants : crée un jeu de clés de type « API OVHcloud ».",
        )
    try:
        return await ovh_col.client_for_credential(account["credential_id"], account["endpoint"])
    except ovh_col.OVHError as exc:
        raise CloudError(str(exc), exc.hint) from exc


# ---------------------------------------------------------- synchronisation
async def sync_account(account: dict) -> dict:
    """Relève un compte, met à jour ses ressources et son historique."""
    client = await client_for_account(account)
    meta = account.get("meta") or {}

    # Régions à balayer : la liste courte tant que le dernier balayage complet
    # est récent, sinon toutes celles du projet.
    regions = meta.get("storage_regions")
    scanned_at = float(meta.get("regions_scanned_at") or 0)
    full_scan = not regions or (_now() - scanned_at) > REGION_RESCAN_SECONDS

    try:
        snapshot = await client.snapshot(account["project_id"], None if full_scan else regions)
    except ovh_col.OVHError as exc:
        await _mark_failed(account, str(exc))
        raise CloudError(str(exc), exc.hint) from exc
    finally:
        await client.close()

    resources = await _save_resources(account, snapshot)
    await _write_usage(account, resources, snapshot)
    await _check_thresholds(account, resources)

    patch: dict[str, Any] = {"last_sync_errors": snapshot["errors"]}
    if full_scan:
        patch["storage_regions"] = snapshot["storage_regions"]
        patch["regions_scanned_at"] = _now()
    patch["cost"] = snapshot["cost"]

    await execute(
        "UPDATE cloud_accounts SET status = 'online', last_error = :err, last_sync = now(), "
        "meta = meta || CAST(:meta AS jsonb) WHERE id = :id",
        {"id": account["id"], "meta": json.dumps(patch, default=str),
         "err": "; ".join(snapshot["errors"]) or None},
    )

    bus.publish("cloud", {"account_id": account["id"], "resources": len(resources),
                          "cost": snapshot["cost"].get("current")})
    log.info("Compte cloud « %s » synchronisé : %d ressource(s)", account["name"], len(resources))
    return {"resources": resources, "cost": snapshot["cost"], "errors": snapshot["errors"]}


async def _mark_failed(account: dict, message: str) -> None:
    previous = account.get("status")
    await execute(
        "UPDATE cloud_accounts SET status = 'offline', last_error = :err WHERE id = :id",
        {"id": account["id"], "err": message[:500]},
    )
    if previous != "offline":
        await log_event(None, "warning", "cloud",
                        f"Compte cloud « {account['name']} » injoignable", {"erreur": message[:300]})


async def _save_resources(account: dict, snapshot: dict) -> list[dict]:
    """Insère ou met à jour les ressources, et retire celles qui ont disparu."""
    payload = snapshot["resources"]
    # Repère pris avant la première écriture : un balayage qui dure plusieurs
    # minutes ne doit pas faire passer pour disparues les ressources qu'il vient
    # lui-même d'enregistrer.
    started = await fetch_one("SELECT now() AS ts")
    for resource in payload:
        await execute(
            """INSERT INTO cloud_resources (account_id, kind, ext_id, name, region, status,
                                            size_bytes, objects, price_month, meta, last_seen)
               VALUES (:account_id, :kind, :ext_id, :name, :region, :status,
                       :size_bytes, :objects, :price_month, CAST(:meta AS jsonb), now())
               ON CONFLICT (account_id, ext_id) DO UPDATE SET
                 name = EXCLUDED.name, region = EXCLUDED.region, status = EXCLUDED.status,
                 size_bytes = EXCLUDED.size_bytes, objects = EXCLUDED.objects,
                 price_month = EXCLUDED.price_month,
                 meta = cloud_resources.meta || EXCLUDED.meta,
                 last_seen = now()""",
            {
                "account_id": account["id"], "kind": resource["kind"], "ext_id": resource["ext_id"],
                "name": resource["name"], "region": resource.get("region"),
                "status": resource.get("status"), "size_bytes": resource.get("size_bytes"),
                "objects": resource.get("objects"), "price_month": resource.get("price_month"),
                "meta": json.dumps(resource.get("meta") or {}, default=str),
            },
        )

    # Une ressource absente d'une catégorie pourtant relevée sans erreur a bien
    # été supprimée côté fournisseur ; une catégorie en échec ne prouve rien.
    collected = snapshot.get("collected_kinds") or []
    if collected:
        await execute(
            "UPDATE cloud_resources SET status = 'disparu' "
            "WHERE account_id = :id AND kind = ANY(:kinds) AND last_seen < :started "
            "AND status <> 'disparu'",
            {"id": account["id"], "kinds": list(collected), "started": started["ts"]},
        )

    return await fetch_all(
        "SELECT * FROM cloud_resources WHERE account_id = :id ORDER BY kind, name",
        {"id": account["id"]},
    )


async def _write_usage(account: dict, resources: list[dict], snapshot: dict) -> None:
    """Un point d'historique par ressource et par métrique, plus le total."""
    rows: list[dict] = []

    def add(metric: str, value: Any, resource_id: int | None = None) -> None:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            rows.append({"account_id": account["id"], "resource_id": resource_id,
                         "metric": metric, "value": float(value)})

    stored = objects = 0.0
    for resource in resources:
        if resource["status"] == "disparu":
            continue
        add("storage.bytes", resource.get("size_bytes"), resource["id"])
        add("storage.objects", resource.get("objects"), resource["id"])
        add("cost.month", resource.get("price_month"), resource["id"])
        if resource["kind"] in BUCKET_KINDS:
            stored += resource.get("size_bytes") or 0.0
            objects += resource.get("objects") or 0.0

    add("storage.bytes", stored)
    add("storage.objects", objects)
    add("cost.current", snapshot["cost"].get("current"))
    add("cost.forecast", snapshot["cost"].get("forecast"))
    add("resources.count", len([r for r in resources if r["status"] != "disparu"]))

    if rows:
        await execute_many(
            "INSERT INTO cloud_usage (time, account_id, resource_id, metric, value) "
            "VALUES (now(), :account_id, :resource_id, :metric, :value)",
            rows,
        )


async def _check_thresholds(account: dict, resources: list[dict]) -> None:
    """Alerte quand un bucket dépasse le seuil qu'on lui a fixé."""
    for resource in resources:
        quota = resource.get("quota_bytes")
        size = resource.get("size_bytes")
        if not quota or not size or size < quota:
            continue
        percent = 100.0 * size / quota
        await log_event(
            resource.get("host_id"), "warning", "cloud",
            f"Le stockage « {resource['name']} » dépasse son seuil ({percent:.0f} %)",
            {"compte": account["name"], "region": resource.get("region"),
             "taille": size, "seuil": quota},
        )
        await notify.dispatch(
            "cloud_quota",
            f"Stockage cloud « {resource['name']} » à {percent:.0f} % du seuil",
            notify.format_event(account["name"], "avertissement",
                                f"Le stockage objet « {resource['name']} » dépasse le seuil fixé.",
                                {"Région": resource.get("region") or "—",
                                 "Datastore PBS": resource.get("link_ref") or "aucun"}),
            dedupe_key=f"cloud_quota:{resource['id']}",
        )


# ------------------------------------------------------- corrélation PBS
async def pbs_bucket_map() -> dict[str, dict]:
    """Buckets S3 déclarés dans les PBS supervisés, indexés par nom de bucket.

    PBS range le backend d'un datastore dans sa configuration sous une forme qui
    a bougé d'une version à l'autre (chaîne « type=s3,…​ », ou champs séparés) :
    on cherche donc le nom du bucket partout où il peut se trouver plutôt que de
    parier sur une clé précise. Un jeton sans droit de lecture sur `/config`
    n'empêche rien — le rapprochement se fait alors à la main depuis la page.
    """
    hosts = await fetch_all("SELECT * FROM hosts WHERE kind = 'pbs' AND enabled")
    found: dict[str, dict] = {}

    for host in hosts:
        client = await pbs_col.client_for_host(host)
        try:
            datastores = await client.get("/config/datastore") or []
            endpoints: dict[str, dict] = {}
            with contextlib.suppress(pbs_col.PBSError):
                for entry in await client.get("/config/s3-endpoint") or []:
                    if isinstance(entry, dict) and entry.get("id"):
                        endpoints[str(entry["id"])] = entry
        except pbs_col.PBSError as exc:
            log.debug("Configuration PBS illisible sur %s : %s", host["name"], exc)
            continue
        finally:
            await client.close()

        for store in datastores:
            if not isinstance(store, dict):
                continue
            bucket, client_id = _bucket_of(store)
            if not bucket and client_id and client_id in endpoints:
                bucket, _ = _bucket_of(endpoints[client_id])
            if not bucket:
                continue
            found[bucket] = {
                "host_id": host["id"],
                "host_name": host["name"],
                "datastore": store.get("name") or store.get("id"),
                "endpoint": (endpoints.get(client_id or "") or {}).get("endpoint"),
            }
    return found


def _bucket_of(entry: dict) -> tuple[str | None, str | None]:
    """(nom du bucket, identifiant du client S3) trouvés dans une entrée."""
    bucket = entry.get("bucket") if isinstance(entry.get("bucket"), str) else None
    client_id = None
    for key in ("backend", "s3-client", "client"):
        value = entry.get(key)
        if isinstance(value, dict):
            bucket = bucket or (value.get("bucket") if isinstance(value.get("bucket"), str) else None)
            client_id = client_id or value.get("client") or value.get("id")
        elif isinstance(value, str):
            match = BUCKET_RE.search(value)
            if match:
                bucket = bucket or match.group(1)
            client_match = re.search(r"client[=:]\s*([\w.-]+)", value)
            if client_match:
                client_id = client_id or client_match.group(1)
            elif key in ("s3-client", "client") and "=" not in value:
                # Champ dédié : la valeur est l'identifiant du client, tel quel.
                client_id = client_id or value.strip()
    return bucket, (str(client_id) if client_id else None)


async def link_pbs_datastores() -> int:
    """Rapproche buckets et datastores PBS, sans écraser un lien posé à la main."""
    try:
        mapping = await pbs_bucket_map()
    except Exception as exc:  # noqa: BLE001 — la corrélation est un bonus, jamais bloquante
        log.debug("Corrélation PBS impossible : %s", exc)
        return 0
    if not mapping:
        return 0

    linked = 0
    resources = await fetch_all(
        "SELECT * FROM cloud_resources WHERE kind = ANY(:kinds)", {"kinds": list(BUCKET_KINDS)}
    )
    for resource in resources:
        if (resource.get("meta") or {}).get("link_manual"):
            continue
        match = mapping.get(resource["name"])
        if not match or (resource.get("link_ref") == match["datastore"]
                         and resource.get("host_id") == match["host_id"]):
            continue
        await execute(
            "UPDATE cloud_resources SET host_id = :host_id, link_ref = :ref, "
            "meta = meta || CAST(:meta AS jsonb) WHERE id = :id",
            {"id": resource["id"], "host_id": match["host_id"], "ref": match["datastore"],
             "meta": json.dumps({"link_source": "pbs", "pbs_endpoint": match.get("endpoint")})},
        )
        linked += 1
    return linked


# ------------------------------------------------------------- historique
async def history(resource_id: int, days: int = 30) -> list[dict]:
    rows = await fetch_all(
        """SELECT extract(epoch FROM time_bucket(make_interval(secs => :bucket), time)) AS t,
                  metric, avg(value) AS value
           FROM cloud_usage
           WHERE resource_id = :id AND time > now() - make_interval(days => :days)
           GROUP BY t, metric ORDER BY t""",
        {"id": resource_id, "days": days, "bucket": max(3600, days * 86400 // 240)},
    )
    return [{"t": float(r["t"]), "metric": r["metric"], "value": float(r["value"])} for r in rows]


async def trend(resource_id: int, days: int = 7) -> dict[str, float | None]:
    """Croissance moyenne en octets par jour, mesurée sur l'historique réel.

    La pente se calcule sur l'écart de temps effectivement couvert : un compte
    ajouté hier ne doit pas voir sa croissance divisée par sept.
    """
    row = await fetch_one(
        """SELECT (array_agg(value ORDER BY time))[1] AS first,
                  (array_agg(value ORDER BY time DESC))[1] AS last,
                  extract(epoch FROM max(time) - min(time)) AS span
           FROM cloud_usage
           WHERE resource_id = :id AND metric = 'storage.bytes'
             AND time > now() - make_interval(days => :days)""",
        {"id": resource_id, "days": days},
    )
    if not row or row["first"] is None or row["last"] is None:
        return {"per_day": None, "delta": None, "span_days": None}
    span = float(row["span"] or 0)
    delta = float(row["last"]) - float(row["first"])
    # Sous six heures d'historique, la pente ne veut encore rien dire.
    per_day = delta / (span / 86400) if span >= 21600 else None
    return {"per_day": per_day, "delta": delta, "span_days": round(span / 86400, 2)}


# ------------------------------------------------------------------ boucle
def _now() -> float:
    return time.time()


async def run_periodic() -> None:
    """Réveil régulier : chaque compte est relevé selon son propre intervalle."""
    await asyncio.sleep(20)  # laisse le démarrage se terminer
    while True:
        try:
            due = await fetch_all(
                "SELECT * FROM cloud_accounts WHERE enabled AND project_id IS NOT NULL "
                "AND (last_sync IS NULL OR last_sync < now() - make_interval(mins => sync_minutes))"
            )
            for account in due:
                try:
                    await sync_account(account)
                except CloudError as exc:
                    log.warning("Synchronisation du compte « %s » échouée : %s", account["name"], exc)
                except Exception as exc:  # noqa: BLE001
                    log.exception("Erreur inattendue sur le compte « %s » : %s", account["name"], exc)
            if due:
                await link_pbs_datastores()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle cloud en erreur : %s", exc)
        await asyncio.sleep(TICK_SECONDS)
