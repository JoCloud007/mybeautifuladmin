"""API du cloud public : comptes, ressources, volumétrie du stockage objet."""
from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field

from .. import cloud
from ..collectors import ovh as ovh_col
from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/cloud", tags=["cloud public"])

BUCKET_KINDS = list(cloud.BUCKET_KINDS)


class AccountIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    provider: Literal["ovh"] = "ovh"
    endpoint: str = "ovh-eu"
    project_id: str | None = None
    credential_id: int | None = None
    sync_minutes: int = Field(30, ge=5, le=1440)
    enabled: bool = True


class AccountPatch(BaseModel):
    name: str | None = None
    endpoint: str | None = None
    project_id: str | None = None
    credential_id: int | None = None
    sync_minutes: int | None = Field(None, ge=5, le=1440)
    enabled: bool | None = None


class ResourcePatch(BaseModel):
    """Ce que l'exploitant sait et que l'API du fournisseur ignore."""

    quota_bytes: float | None = None
    notes: str | None = None
    host_id: int | None = None
    link_ref: str | None = None


class ProbeIn(BaseModel):
    """Test d'un jeu de clés avant d'enregistrer un compte."""

    credential_id: int
    endpoint: str = "ovh-eu"


def _fail(exc: cloud.CloudError | ovh_col.OVHError) -> HTTPException:
    return HTTPException(status.HTTP_400_BAD_REQUEST,
                         {"message": str(exc), "hint": getattr(exc, "hint", None)})


# ------------------------------------------------------------------ synthèse
@router.get("")
async def overview(user: dict = Depends(current_user)) -> dict:
    accounts = await fetch_all(
        "SELECT a.*, c.name AS credential_name FROM cloud_accounts a "
        "LEFT JOIN credentials c ON c.id = a.credential_id ORDER BY a.name"
    )
    resources = await fetch_all(
        """SELECT r.*, a.name AS account_name, a.provider, h.name AS pbs_name
           FROM cloud_resources r
           JOIN cloud_accounts a ON a.id = r.account_id
           LEFT JOIN hosts h ON h.id = r.host_id
           ORDER BY r.kind, r.name"""
    )

    # Croissance : une seule requête pour tout le stockage, plutôt qu'une par bucket.
    trends = await fetch_all(
        """SELECT resource_id,
                  (array_agg(value ORDER BY time))[1] AS first,
                  (array_agg(value ORDER BY time DESC))[1] AS last,
                  extract(epoch FROM max(time) - min(time)) AS span
           FROM cloud_usage
           WHERE metric = 'storage.bytes' AND resource_id IS NOT NULL
             AND time > now() - interval '30 days'
           GROUP BY resource_id"""
    )
    by_resource = {t["resource_id"]: t for t in trends}

    for resource in resources:
        resource["trend"] = _trend(by_resource.get(resource["id"]))
        resource["days_to_quota"] = _days_to_quota(resource)

    buckets = [r for r in resources if r["kind"] in BUCKET_KINDS and r["status"] != "disparu"]
    return {
        "accounts": accounts,
        "resources": resources,
        "summary": {
            "accounts": len(accounts),
            "accounts_online": len([a for a in accounts if a["status"] == "online"]),
            "buckets": len(buckets),
            "stored_bytes": sum(b["size_bytes"] or 0 for b in buckets),
            "objects": sum(b["objects"] or 0 for b in buckets),
            "cost_current": sum(float((a.get("meta") or {}).get("cost", {}).get("current") or 0)
                                for a in accounts),
            "cost_forecast": sum(float((a.get("meta") or {}).get("cost", {}).get("forecast") or 0)
                                 for a in accounts),
            "currency": next((((a.get("meta") or {}).get("cost", {}).get("currency"))
                              for a in accounts if (a.get("meta") or {}).get("cost")), "EUR"),
            "linked_pbs": len([b for b in buckets if b.get("link_ref")]),
            "by_kind": _count_by(resources, "kind"),
            "by_region": _count_by([r for r in resources if r["status"] != "disparu"], "region"),
        },
    }


def _trend(row: dict | None) -> dict[str, Any]:
    if not row or row["first"] is None or row["last"] is None:
        return {"per_day": None, "delta": None}
    span = float(row["span"] or 0)
    delta = float(row["last"]) - float(row["first"])
    return {"per_day": delta / (span / 86400) if span >= 21600 else None, "delta": delta}


def _days_to_quota(resource: dict) -> float | None:
    """Jours restants avant le seuil, au rythme observé."""
    quota, size = resource.get("quota_bytes"), resource.get("size_bytes")
    per_day = (resource.get("trend") or {}).get("per_day")
    if not quota or not size or not per_day or per_day <= 0 or size >= quota:
        return None
    return round((quota - size) / per_day, 1)


def _count_by(resources: list[dict], field: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for resource in resources:
        key = resource.get(field) or "—"
        out[key] = out.get(key, 0) + 1
    return out


# ------------------------------------------------------------------- comptes
@router.get("/accounts")
async def list_accounts(user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        "SELECT a.*, c.name AS credential_name, "
        "  (SELECT count(*) FROM cloud_resources r WHERE r.account_id = a.id) AS resources_count "
        "FROM cloud_accounts a LEFT JOIN credentials c ON c.id = a.credential_id ORDER BY a.name"
    )


@router.post("/probe")
async def probe(payload: ProbeIn, user: dict = Depends(current_user)) -> dict:
    """Vérifie un jeu de clés et liste les projets qu'il ouvre."""
    try:
        client = await ovh_col.client_for_credential(payload.credential_id, payload.endpoint)
    except ovh_col.OVHError as exc:
        raise _fail(exc) from exc
    try:
        identity = await client.me()
        projects = await client.projects()
    except ovh_col.OVHError as exc:
        raise _fail(exc) from exc
    finally:
        await client.close()

    return {
        "identity": {"nichandle": identity.get("nichandle"), "email": identity.get("email"),
                     "country": identity.get("country")},
        "projects": projects,
    }


@router.post("/accounts", status_code=status.HTTP_201_CREATED)
async def create_account(payload: AccountIn, user: dict = Depends(current_user)) -> dict:
    existing = await fetch_one(
        "SELECT id FROM cloud_accounts WHERE provider = :p AND project_id = :pid",
        {"p": payload.provider, "pid": payload.project_id},
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Ce projet est déjà enregistré")

    account_id = await execute(
        """INSERT INTO cloud_accounts (name, provider, endpoint, project_id, credential_id,
                                       sync_minutes, enabled)
           VALUES (:name, :provider, :endpoint, :project_id, :credential_id,
                   :sync_minutes, :enabled) RETURNING id""",
        payload.model_dump(),
    )
    return await fetch_one("SELECT * FROM cloud_accounts WHERE id = :id", {"id": account_id})


@router.patch("/accounts/{account_id}")
async def update_account(account_id: int, payload: AccountPatch,
                         user: dict = Depends(current_user)) -> dict:
    fields = payload.model_dump(exclude_unset=True)
    if fields:
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        await execute(f"UPDATE cloud_accounts SET {sets} WHERE id = :id", {**fields, "id": account_id})
    account = await fetch_one("SELECT * FROM cloud_accounts WHERE id = :id", {"id": account_id})
    if not account:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Compte introuvable")
    return account


@router.delete("/accounts/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(account_id: int, user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM cloud_accounts WHERE id = :id", {"id": account_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/accounts/{account_id}/sync")
async def sync_now(account_id: int, user: dict = Depends(current_user)) -> dict:
    account = await fetch_one("SELECT * FROM cloud_accounts WHERE id = :id", {"id": account_id})
    if not account:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Compte introuvable")
    if not account["project_id"]:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            {"message": "Aucun projet sélectionné sur ce compte",
                             "hint": "Modifie le compte et choisis un projet Public Cloud."})
    try:
        result = await cloud.sync_account(account)
    except cloud.CloudError as exc:
        raise _fail(exc) from exc

    linked = await cloud.link_pbs_datastores()
    return {"resources": len(result["resources"]), "cost": result["cost"],
            "errors": result["errors"], "linked_pbs": linked}


# --------------------------------------------------------------- ressources
@router.get("/resources/{resource_id}")
async def resource_detail(resource_id: int, days: int = Query(30, ge=1, le=365),
                          user: dict = Depends(current_user)) -> dict:
    resource = await fetch_one(
        "SELECT r.*, a.name AS account_name, a.provider, a.endpoint, h.name AS pbs_name "
        "FROM cloud_resources r JOIN cloud_accounts a ON a.id = r.account_id "
        "LEFT JOIN hosts h ON h.id = r.host_id WHERE r.id = :id",
        {"id": resource_id},
    )
    if not resource:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ressource introuvable")
    return {
        "resource": resource,
        "history": await cloud.history(resource_id, days),
        "trend_7d": await cloud.trend(resource_id, 7),
        "trend_30d": await cloud.trend(resource_id, 30),
    }


@router.patch("/resources/{resource_id}")
async def update_resource(resource_id: int, payload: ResourcePatch,
                          user: dict = Depends(current_user)) -> dict:
    fields = payload.model_dump(exclude_unset=True)
    # Un lien posé à la main ne doit plus être remplacé par la détection auto.
    manual = "host_id" in fields or "link_ref" in fields
    if fields:
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        extra = ", meta = meta || '{\"link_manual\": true}'::jsonb" if manual else ""
        await execute(f"UPDATE cloud_resources SET {sets}{extra} WHERE id = :id",
                      {**fields, "id": resource_id})
    resource = await fetch_one("SELECT * FROM cloud_resources WHERE id = :id", {"id": resource_id})
    if not resource:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ressource introuvable")
    return resource


@router.post("/link-pbs")
async def link_pbs(user: dict = Depends(current_user)) -> dict:
    """Relance la détection des datastores PBS adossés aux buckets."""
    return {"linked": await cloud.link_pbs_datastores(),
            "buckets": await cloud.pbs_bucket_map()}
