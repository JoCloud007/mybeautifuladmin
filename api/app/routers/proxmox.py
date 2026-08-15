"""Administration des invités Proxmox : cycle de vie, snapshots, sauvegardes,
clonage, migration et ajustement des ressources."""
from __future__ import annotations

import re
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from ..bus import bus
from ..collectors.proxmox import ProxmoxError, client_for_host
from ..db import execute, fetch_all, fetch_one
from ..poller import log_event, supervisor
from ..security import current_user

router = APIRouter(prefix="/proxmox", tags=["proxmox"])

GuestKind = Literal["qemu", "lxc"]
SNAPSHOT_RE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")


class ConfigIn(BaseModel):
    cores: int | None = Field(default=None, ge=1, le=256)
    memory: int | None = Field(default=None, ge=64, description="En Mio")
    name: str | None = None
    description: str | None = None
    onboot: bool | None = None
    tags: str | None = None


class SnapshotIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    description: str = ""
    vmstate: bool = False


class CloneIn(BaseModel):
    name: str = Field(min_length=1)
    newid: int | None = None
    full: bool = True
    target: str | None = None


class MigrateIn(BaseModel):
    target: str = Field(min_length=1)
    online: bool = True
    with_local_disks: bool = False


class BackupIn(BaseModel):
    storage: str = Field(min_length=1)
    mode: Literal["snapshot", "suspend", "stop"] = "snapshot"
    compress: Literal["zstd", "gzip", "lzo", "0"] = "zstd"
    notes: str = ""


# ------------------------------------------------------------------ lecture
@router.get("/hosts")
async def clusters(user: dict = Depends(current_user)) -> list[dict]:
    hosts = await fetch_all("SELECT * FROM hosts WHERE kind = 'proxmox' ORDER BY name")
    live = bus.latest("metrics.")
    for host in hosts:
        sample = live.get(f"metrics.{host['id']}", {})
        host["nodes"] = sample.get("nodes", [])
        host["storages"] = sample.get("storages", [])
        host["guests"] = sample.get("guests", [])
        host["live"] = {k: v for k, v in sample.items()
                        if isinstance(v, (int, float)) and not isinstance(v, bool)}
    return hosts


@router.get("/candidates")
async def candidates(user: dict = Depends(current_user)) -> list[dict]:
    """Hôtes Linux qui portent /etc/pve : ils gagneraient à passer en type « proxmox »."""
    hosts = await fetch_all(
        "SELECT id, name, address, port, credential_id, meta FROM hosts "
        "WHERE kind <> 'proxmox' AND meta ? 'is_pve'"
    )
    return [{
        "id": h["id"], "name": h["name"], "address": h["address"],
        "version": (h.get("meta") or {}).get("pve_version"),
    } for h in hosts]


@router.get("/{host_id}/guests")
async def guests(host_id: int, user: dict = Depends(current_user)) -> dict:
    """Inventaire VM/LXC : depuis le flux live, avec repli sur la base."""
    host = await _require_pve(host_id)
    sample = bus.latest(f"metrics.{host_id}").get(f"metrics.{host_id}", {})
    guests = sample.get("guests")

    if guests is None:
        rows = await fetch_all(
            "SELECT * FROM containers WHERE host_id = :h AND kind IN ('qemu','lxc') ORDER BY name",
            {"h": host_id},
        )
        guests = [{
            "vmid": (r["stats"] or {}).get("vmid"),
            "name": r["name"], "type": r["kind"], "node": (r["stats"] or {}).get("node"),
            "status": r["state"], "cpu": (r["stats"] or {}).get("cpu", 0),
            "mem": (r["stats"] or {}).get("mem", 0),
            "maxmem": (r["stats"] or {}).get("mem_limit", 0),
            "mem_percent": (r["stats"] or {}).get("mem_percent", 0),
            "uptime": (r["stats"] or {}).get("uptime", 0),
        } for r in rows]

    return {
        "guests": guests,
        "nodes": sample.get("nodes", (host.get("meta") or {}).get("nodes", [])),
        "storages": sample.get("storages", []),
        "summary": {
            "total": len(guests),
            "running": len([g for g in guests if g.get("status") == "running"]),
            "qemu": len([g for g in guests if g.get("type") == "qemu"]),
            "lxc": len([g for g in guests if g.get("type") == "lxc"]),
        },
    }


@router.get("/{host_id}/guests/{kind}/{vmid}")
async def guest_detail(host_id: int, kind: GuestKind, vmid: int,
                       user: dict = Depends(current_user)) -> dict:
    host = await _require_pve(host_id)
    node = await _node_of(host, kind, vmid)
    client = await client_for_host(host)
    try:
        config = await client.guest_config(node, kind, vmid)
        snapshots = await client.snapshots(node, kind, vmid)
        rrd = await client.guest_rrd(node, kind, vmid, "hour")
        backups = await client.backups(node, vmid)
        storages = await client.backup_storages(node)
        console = client.console_url(node, kind, vmid)
    except ProxmoxError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()

    return {
        "node": node,
        "vmid": vmid,
        "kind": kind,
        "config": _readable_config(config, kind),
        "raw_config": config,
        "snapshots": [s for s in snapshots if not s["current"]],
        "history": rrd,
        "backups": backups,
        "backup_storages": storages,
        "console_url": console,
    }


def _readable_config(config: dict, kind: str) -> dict[str, Any]:
    """Extrait les champs qu'on sait présenter et modifier."""
    disks, networks = [], []
    for key, value in config.items():
        if re.match(r"^(scsi|virtio|ide|sata|rootfs|mp)\d*$", key) and isinstance(value, str):
            size = re.search(r"size=(\S+?)(?:,|$)", value)
            disks.append({"slot": key, "size": size.group(1) if size else None,
                          "spec": value.split(",")[0]})
        elif re.match(r"^net\d+$", key) and isinstance(value, str):
            bridge = re.search(r"bridge=(\w+)", value)
            mac = re.search(r"(?:virtio|hwaddr)=([0-9A-Fa-f:]{17})", value)
            networks.append({"slot": key, "bridge": bridge.group(1) if bridge else None,
                             "mac": mac.group(1) if mac else None, "spec": value})
    return {
        "name": config.get("name") or config.get("hostname"),
        "cores": config.get("cores"),
        "sockets": config.get("sockets", 1),
        "memory": config.get("memory"),
        "balloon": config.get("balloon"),
        "onboot": bool(config.get("onboot")),
        "description": (config.get("description") or "").strip(),
        "tags": [t for t in (config.get("tags") or "").split(";") if t],
        "ostype": config.get("ostype"),
        "boot": config.get("boot"),
        "disks": disks,
        "networks": networks,
    }


# ------------------------------------------------------------------ actions
@router.post("/{host_id}/guests/{kind}/{vmid}/power/{action}")
async def power(host_id: int, kind: GuestKind, vmid: int, action: str,
                user: dict = Depends(current_user)) -> dict:
    allowed = {"start", "stop", "shutdown", "reboot", "reset", "suspend", "resume"}
    if action not in allowed:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Action inconnue : {action}")
    return await _run(host_id, kind, vmid, f"pve {action}",
                      lambda client, node: client.guest_action(node, kind, vmid, action),
                      user, level="warning" if action in ("stop", "reset") else "info")


@router.patch("/{host_id}/guests/{kind}/{vmid}/config")
async def set_config(host_id: int, kind: GuestKind, vmid: int, payload: ConfigIn,
                     user: dict = Depends(current_user)) -> dict:
    fields = payload.model_dump(exclude_unset=True, exclude_none=True)
    if "onboot" in fields:
        fields["onboot"] = 1 if fields["onboot"] else 0
    if kind == "lxc" and "name" in fields:
        fields["hostname"] = fields.pop("name")
    if not fields:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aucune modification demandée")
    return await _run(host_id, kind, vmid, "pve config",
                      lambda client, node: client.set_guest_config(node, kind, vmid, fields), user)


@router.post("/{host_id}/guests/{kind}/{vmid}/snapshots")
async def create_snapshot(host_id: int, kind: GuestKind, vmid: int, payload: SnapshotIn,
                          user: dict = Depends(current_user)) -> dict:
    if not SNAPSHOT_RE.match(payload.name):
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Nom de snapshot invalide (lettres, chiffres, - et _)")
    return await _run(
        host_id, kind, vmid, f"pve snapshot {payload.name}",
        lambda client, node: client.create_snapshot(node, kind, vmid, payload.name,
                                                    payload.description, payload.vmstate),
        user,
    )


@router.delete("/{host_id}/guests/{kind}/{vmid}/snapshots/{name}")
async def delete_snapshot(host_id: int, kind: GuestKind, vmid: int, name: str,
                          user: dict = Depends(current_user)) -> dict:
    return await _run(host_id, kind, vmid, f"pve snapshot delete {name}",
                      lambda client, node: client.delete_snapshot(node, kind, vmid, name), user)


@router.post("/{host_id}/guests/{kind}/{vmid}/snapshots/{name}/rollback")
async def rollback(host_id: int, kind: GuestKind, vmid: int, name: str,
                   user: dict = Depends(current_user)) -> dict:
    return await _run(host_id, kind, vmid, f"pve rollback {name}",
                      lambda client, node: client.rollback_snapshot(node, kind, vmid, name),
                      user, level="warning")


@router.post("/{host_id}/guests/{kind}/{vmid}/clone")
async def clone(host_id: int, kind: GuestKind, vmid: int, payload: CloneIn,
                user: dict = Depends(current_user)) -> dict:
    host = await _require_pve(host_id)
    client = await client_for_host(host)
    try:
        newid = payload.newid or await client.next_id()
        node = await _node_of(host, kind, vmid)
        task = await client.clone(node, kind, vmid, newid, payload.name,
                                  payload.full, payload.target)
    except ProxmoxError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()
    await log_event(host_id, "info", "proxmox",
                    f"Clone de {kind} {vmid} → {newid} ({payload.name}) par {user['username']}")
    _refresh(host_id)
    return {"ok": True, "newid": newid, "task": task}


@router.post("/{host_id}/guests/{kind}/{vmid}/migrate")
async def migrate(host_id: int, kind: GuestKind, vmid: int, payload: MigrateIn,
                  user: dict = Depends(current_user)) -> dict:
    return await _run(
        host_id, kind, vmid, f"pve migrate → {payload.target}",
        lambda client, node: client.migrate(node, kind, vmid, payload.target,
                                            payload.online, payload.with_local_disks),
        user, level="warning",
    )


@router.post("/{host_id}/guests/{kind}/{vmid}/backup")
async def backup(host_id: int, kind: GuestKind, vmid: int, payload: BackupIn,
                 user: dict = Depends(current_user)) -> dict:
    return await _run(
        host_id, kind, vmid, "pve backup",
        lambda client, node: client.backup(node, vmid, payload.storage, payload.mode,
                                           payload.compress, payload.notes),
        user,
    )


@router.get("/{host_id}/tasks")
async def tasks(host_id: int, node: str | None = Query(default=None),
                user: dict = Depends(current_user)) -> list[dict]:
    host = await _require_pve(host_id)
    client = await client_for_host(host)
    try:
        nodes = [node] if node else ((host.get("meta") or {}).get("nodes") or [])
        out: list[dict] = []
        for name in nodes:
            out.extend([{**t, "node": name} for t in await client.tasks(name)])
    except ProxmoxError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()
    out.sort(key=lambda t: t.get("started") or 0, reverse=True)
    return out[:60]


@router.post("/{host_id}/nodes/{node}/{action}")
async def node_power(host_id: int, node: str, action: str,
                     user: dict = Depends(current_user)) -> dict:
    if action not in ("reboot", "shutdown"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Action inconnue : {action}")
    host = await _require_pve(host_id)
    client = await client_for_host(host)
    try:
        await client.node_action(node, action)
    except ProxmoxError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()
    await log_event(host_id, "critical", "proxmox",
                    f"{action} du nœud {node} demandé par {user['username']}")
    return {"ok": True}


# ------------------------------------------------------------------ helpers
async def _run(host_id: int, kind: str, vmid: int, label: str, call, user: dict,
               level: str = "info") -> dict:
    host = await _require_pve(host_id)
    node = await _node_of(host, kind, vmid)
    log_id = await execute(
        "INSERT INTO action_logs (host_id, target, action, status, username) "
        "VALUES (:h, :t, :a, 'running', :u) RETURNING id",
        {"h": host_id, "t": f"{kind}/{vmid}", "a": label, "u": user["username"]},
    )
    client = await client_for_host(host)
    try:
        result = await call(client, node)
    except ProxmoxError as exc:
        await execute("UPDATE action_logs SET status='failed', output=:o, ended_at=now() WHERE id=:id",
                      {"o": str(exc)[:2000], "id": log_id})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()

    await execute("UPDATE action_logs SET status='success', output=:o, ended_at=now() WHERE id=:id",
                  {"o": str(result)[:2000], "id": log_id})
    await log_event(host_id, level, "proxmox", f"{label} sur {kind} {vmid} ({node})")
    _refresh(host_id)
    return {"ok": True, "task": result, "log_id": log_id}


def _refresh(host_id: int) -> None:
    """Force la relecture de l'inventaire au prochain cycle."""
    worker = supervisor.workers.get(host_id)
    if worker:
        worker.last_containers = 0


async def _node_of(host: dict, kind: str, vmid: int) -> str:
    """Retrouve le nœud qui héberge l'invité — l'API Proxmox l'exige partout."""
    sample = bus.latest(f"metrics.{host['id']}").get(f"metrics.{host['id']}", {})
    for guest in sample.get("guests") or []:
        if guest.get("vmid") == vmid and guest.get("type") == kind:
            return guest["node"]

    row = await fetch_one(
        "SELECT stats FROM containers WHERE host_id = :h AND ext_id = :e",
        {"h": host["id"], "e": f"{kind}/{vmid}"},
    )
    node = ((row or {}).get("stats") or {}).get("node")
    if node:
        return node

    nodes = (host.get("meta") or {}).get("nodes") or []
    if nodes:
        return nodes[0]
    raise HTTPException(status.HTTP_404_NOT_FOUND, "Nœud Proxmox introuvable pour cet invité")


async def _require_pve(host_id: int) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'proxmox'",
                           {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Hyperviseur Proxmox introuvable")
    return host
