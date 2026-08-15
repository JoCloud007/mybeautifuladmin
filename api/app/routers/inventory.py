from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from ..bus import bus
from ..db import execute, fetch_all, fetch_one
from ..poller import supervisor
from ..security import current_user

router = APIRouter(prefix="/inventory", tags=["inventaire"])


class InventoryPatch(BaseModel):
    name: str | None = None
    address: str | None = None
    port: int | None = None
    # 0 ou null détache l'identifiant ; un entier l'associe.
    credential_id: int | None = None
    category: str | None = None
    location: str | None = None
    notes: str | None = None
    tags: list[str] | None = None
    enabled: bool | None = None


class BulkPatch(BaseModel):
    host_ids: list[int] = Field(min_length=1)
    category: str | None = None
    location: str | None = None
    add_tags: list[str] = []
    remove_tags: list[str] = []
    enabled: bool | None = None


class BulkDelete(BaseModel):
    host_ids: list[int] = Field(min_length=1)


# Champs de la fiche technique que l'utilisateur peut corriger ou compléter.
EDITABLE = (
    "vendor", "model", "version", "serial", "cpu_model", "cpu_count", "mem_total",
    "disk_total", "bios", "chassis", "asset_tag", "purchased_at", "warranty_until",
    "supplier", "cost", "power_watts", "rack", "rack_unit", "ip_management", "comment",
)


def _identity(host: dict, sample: dict) -> dict[str, Any]:
    """Assemble une fiche matérielle homogène quelle que soit la plateforme."""
    meta = host.get("meta") or {}
    info = sample.get("info") or {}

    if host["kind"] == "synology":
        model = info.get("model") or meta.get("model")
        version = info.get("dsm_version") or meta.get("dsm_version")
        vendor = "Synology"
        serial = info.get("serial") or meta.get("serial")
    elif host["kind"] == "proxmox":
        model = ", ".join(meta.get("nodes") or []) or None
        version = meta.get("version")
        vendor = "Proxmox VE"
        serial = None
    else:
        model = meta.get("model")
        version = meta.get("os")
        vendor = meta.get("vendor")
        serial = meta.get("serial")

    disks = meta.get("disks") or []
    detected: dict[str, Any] = {
        "vendor": vendor,
        "model": model,
        "version": version,
        "serial": serial,
        "kernel": meta.get("kernel"),
        "cpu_model": meta.get("cpu_model"),
        "cpu_count": meta.get("cpu_count") or sample.get("cpu.count"),
        "mem_total": meta.get("mem_total") or sample.get("mem.total"),
        "disk_total": sample.get("disk.total") or sum(d.get("size", 0) for d in disks) or None,
        "disks": disks,
        "macs": meta.get("macs") or {},
        "bios": meta.get("bios"),
        "chassis": meta.get("chassis"),
        "virt": meta.get("virt"),
        "updates": meta.get("updates", 0),
        "security_updates": meta.get("security_updates", 0),
        "reboot_required": bool(meta.get("reboot_required")),
        "uptime": sample.get("uptime"),
    }

    overrides = {k: v for k, v in (host.get("overrides") or {}).items()
                 if v not in (None, "")}
    return {
        **detected,
        **overrides,
        # On garde le relevé brut pour afficher « détecté : … » sous un champ corrigé.
        "_detected": {k: detected.get(k) for k in EDITABLE if detected.get(k) is not None},
        "_overridden": sorted(overrides),
    }


@router.get("")
async def inventory(user: dict = Depends(current_user)) -> dict:
    hosts = await fetch_all(
        "SELECT h.*, c.name AS credential_name, c.kind AS credential_kind "
        "FROM hosts h LEFT JOIN credentials c ON c.id = h.credential_id "
        "ORDER BY coalesce(h.category, 'zzz'), h.name"
    )
    live = bus.latest("metrics.")
    containers = await fetch_all(
        "SELECT host_id, count(*) AS n FROM containers GROUP BY host_id"
    )
    counts = {row["host_id"]: row["n"] for row in containers}

    items = []
    for host in hosts:
        sample = live.get(f"metrics.{host['id']}", {})
        items.append({
            **{k: v for k, v in host.items() if k != "meta"},
            "identity": _identity(host, sample),
            "containers": counts.get(host["id"], 0),
        })

    tags = await fetch_all(
        "SELECT unnest(tags) AS tag, count(*) AS n FROM hosts GROUP BY tag ORDER BY n DESC, tag"
    )
    categories = await fetch_all(
        "SELECT category, count(*) AS n FROM hosts WHERE category IS NOT NULL "
        "GROUP BY category ORDER BY category"
    )
    return {
        "hosts": items,
        "tags": [{"tag": t["tag"], "count": t["n"]} for t in tags],
        "categories": [{"category": c["category"], "count": c["n"]} for c in categories],
        "summary": {
            "total": len(items),
            "by_kind": _tally(items, "kind"),
            "by_category": _tally(items, "category"),
            "untagged": len([i for i in items if not i.get("tags")]),
            "updates": sum(i["identity"]["updates"] or 0 for i in items),
            "reboot_required": len([i for i in items if i["identity"]["reboot_required"]]),
        },
    }


def _tally(items: list[dict], field: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for item in items:
        key = item.get(field) or "—"
        out[key] = out.get(key, 0) + 1
    return out


@router.patch("/{host_id}")
async def update_item(host_id: int, payload: InventoryPatch,
                      user: dict = Depends(current_user)) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Hôte introuvable")

    fields = payload.model_dump(exclude_unset=True)
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aucun champ à modifier")

    credential_changed = False
    if "credential_id" in fields:
        cred_id = fields["credential_id"] or None
        fields["credential_id"] = cred_id
        if cred_id:
            cred = await fetch_one("SELECT id, name, kind FROM credentials WHERE id = :id",
                                   {"id": cred_id})
            if not cred:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Identifiant introuvable")
            _check_compatibility(host["kind"], cred["kind"])
        credential_changed = cred_id != host.get("credential_id")

    sets = ", ".join(f"{key} = :{key}" for key in fields)
    # Sur un BMC, la colonne dédiée doit suivre l'identifiant principal.
    if "credential_id" in fields and host["kind"] == "ipmi":
        sets += ", bmc_credential_id = :credential_id"

    await execute(f"UPDATE hosts SET {sets} WHERE id = :id", {**fields, "id": host_id})

    # Changer d'adresse ou d'identifiant invalide la session SSH en cache.
    if credential_changed or "address" in fields or "port" in fields:
        from ..ssh import pool
        pool.drop(host_id)
    await supervisor.sync()

    updated = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    if credential_changed:
        from ..poller import log_event

        name = None
        if updated.get("credential_id"):
            row = await fetch_one("SELECT name FROM credentials WHERE id = :id",
                                  {"id": updated["credential_id"]})
            name = (row or {}).get("name")
        await log_event(host_id, "info", "inventaire",
                        f"Identifiant de « {host['name']} » "
                        + (f"changé pour « {name} »" if name else "détaché")
                        + f" par {user['username']}")
    return updated


# Ce qu'attend chaque type d'hôte, pour refuser un rapprochement impossible.
EXPECTED_KINDS: dict[str, tuple[set[str], str]] = {
    "linux": ({"ssh_key", "ssh_password"}, "une clé SSH ou un mot de passe SSH"),
    "docker": ({"ssh_key", "ssh_password"}, "une clé SSH ou un mot de passe SSH"),
    "proxmox": ({"api_token", "token", "ssh_password"}, "un jeton d'API Proxmox"),
    "pbs": ({"api_token", "token"}, "un jeton d'API PBS"),
    "synology": ({"ssh_password", "basic"}, "un compte DSM (mot de passe)"),
    "homeassistant": ({"token", "api_token"}, "un jeton d'accès longue durée"),
    "ipmi": ({"ssh_password", "basic", "api_token"}, "un compte du contrôleur BMC"),
}


def _check_compatibility(host_kind: str, cred_kind: str) -> None:
    expected = EXPECTED_KINDS.get(host_kind)
    if expected and cred_kind not in expected[0]:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"Un hôte de type « {host_kind} » attend {expected[1]}, "
            f"pas un identifiant de type « {cred_kind} ».",
        )


@router.post("/bulk")
async def bulk_update(payload: BulkPatch, user: dict = Depends(current_user)) -> dict:
    params: dict[str, Any] = {"ids": payload.host_ids}
    sets = []
    if payload.category is not None:
        sets.append("category = :category")
        params["category"] = payload.category or None
    if payload.location is not None:
        sets.append("location = :location")
        params["location"] = payload.location or None
    if payload.enabled is not None:
        sets.append("enabled = :enabled")
        params["enabled"] = payload.enabled
    if payload.add_tags:
        # Union sans doublon, en conservant l'ordre existant.
        sets.append("tags = (SELECT array_agg(DISTINCT t) FROM unnest(tags || :add_tags) AS t)")
        params["add_tags"] = payload.add_tags
    if payload.remove_tags:
        sets.append(
            "tags = coalesce((SELECT array_agg(t) FROM unnest(tags) AS t "
            "WHERE NOT (t = ANY(:remove_tags))), '{}')"
        )
        params["remove_tags"] = payload.remove_tags
    if not sets:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aucune modification demandée")

    await execute(
        f"UPDATE hosts SET {', '.join(sets)} WHERE id = ANY(CAST(:ids AS integer[]))", params
    )
    await supervisor.sync()
    return {"updated": len(payload.host_ids)}


@router.post("/bulk/delete")
async def bulk_delete(payload: BulkDelete, user: dict = Depends(current_user)) -> dict:
    for host_id in payload.host_ids:
        await supervisor.stop_worker(host_id)
    await execute("DELETE FROM hosts WHERE id = ANY(CAST(:ids AS integer[]))",
                  {"ids": payload.host_ids})
    return {"deleted": len(payload.host_ids)}


class IdentityPatch(BaseModel):
    """Correction manuelle de la fiche technique. `null` efface la correction."""

    model_config = {"extra": "forbid"}

    vendor: str | None = None
    model: str | None = None
    version: str | None = None
    serial: str | None = None
    cpu_model: str | None = None
    cpu_count: int | None = None
    mem_total: float | None = None
    disk_total: float | None = None
    bios: str | None = None
    chassis: str | None = None
    asset_tag: str | None = None
    purchased_at: str | None = None
    warranty_until: str | None = None
    supplier: str | None = None
    cost: float | None = None
    power_watts: float | None = None
    rack: str | None = None
    rack_unit: str | None = None
    ip_management: str | None = None
    comment: str | None = None


@router.patch("/{host_id}/identity")
async def update_identity(host_id: int, payload: IdentityPatch,
                          user: dict = Depends(current_user)) -> dict:
    """Écrase champ par champ le relevé automatique.

    Un champ envoyé à `null` supprime la correction : la valeur détectée
    reprend la main au cycle suivant.
    """
    host = await fetch_one("SELECT overrides FROM hosts WHERE id = :id", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Hôte introuvable")

    overrides = dict(host.get("overrides") or {})
    for key, value in payload.model_dump(exclude_unset=True).items():
        if value in (None, ""):
            overrides.pop(key, None)
        else:
            overrides[key] = value

    await execute("UPDATE hosts SET overrides = CAST(:o AS jsonb) WHERE id = :id",
                  {"o": json.dumps(overrides, default=str), "id": host_id})
    updated = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    live = bus.latest("metrics.").get(f"metrics.{host_id}", {})
    return {"ok": True, "identity": _identity(updated, live), "overrides": overrides}


@router.post("/{host_id}/refresh")
async def refresh(host_id: int, user: dict = Depends(current_user)) -> dict:
    """Force la relecture des informations matérielles (cycle lent)."""
    worker = supervisor.workers.get(host_id)
    if not worker:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Aucun collecteur actif pour cet hôte")
    worker.last_slow = 0
    await supervisor.refresh_now(host_id)
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    return {"ok": True, "meta": (host or {}).get("meta", {})}


@router.get("/export")
async def export(user: dict = Depends(current_user)) -> Response:
    """Export CSV du parc, pour une reprise dans un tableur."""
    data = await inventory(user)
    lines = ["nom;type;adresse;categorie;emplacement;etiquettes;constructeur;modele;"
             "version;serie;cpu;coeurs;memoire;conteneurs;statut"]
    for host in data["hosts"]:
        ident = host["identity"]
        lines.append(";".join(str(v or "").replace(";", ",") for v in [
            host["name"], host["kind"], host["address"], host.get("category"),
            host.get("location"), "|".join(host.get("tags") or []),
            ident["vendor"], ident["model"], ident["version"], ident["serial"],
            ident["cpu_model"], ident["cpu_count"],
            round((ident["mem_total"] or 0) / 1e9, 1) or "", host["containers"], host["status"],
        ]))
    return Response(
        "\n".join(lines),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="inventaire-mba.csv"'},
    )
