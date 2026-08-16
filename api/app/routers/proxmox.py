"""Administration des invités Proxmox : cycle de vie, snapshots, sauvegardes,
clonage, migration et ajustement des ressources."""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import secrets
import time
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, status
from pydantic import BaseModel, Field

from ..bus import bus
from ..collectors.proxmox import ProxmoxError, client_for_host
from ..db import execute, fetch_all, fetch_one
from ..poller import log_event, supervisor
from ..security import current_user, ws_user

log = logging.getLogger("mba.pve")

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

    sample = bus.latest(f"metrics.{host_id}").get(f"metrics.{host_id}", {})
    live = next((g for g in (sample.get("guests") or [])
                 if g.get("vmid") == vmid and g.get("type") == kind), {})

    return {
        "node": node,
        "vmid": vmid,
        "kind": kind,
        "status": live.get("status"),
        "live": {k: live.get(k) for k in ("cpu", "mem", "maxmem", "mem_percent", "uptime")},
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


# ------------------------------------------------------------------ console
@router.websocket("/{host_id}/console/{kind}/{vmid}")
async def console(websocket: WebSocket, host_id: int, kind: str, vmid: int) -> None:
    """Relaie la console Proxmox jusqu'au navigateur.

    Le navigateur ne peut pas parler directement à Proxmox : il n'a ni le jeton
    d'API, ni un certificat accepté. MBA ouvre donc le canal côté PVE avec ses
    propres identifiants et fait transiter les octets dans les deux sens.
    """
    await websocket.accept()
    try:
        await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return

    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'proxmox'",
                           {"id": host_id})
    if not host:
        await websocket.send_text(json.dumps({"t": "e", "d": "Hyperviseur introuvable\r\n"}))
        await websocket.close(code=4404)
        return

    client = await client_for_host(host)
    upstream = None
    try:
        node = websocket.query_params.get("node") or await _node_of(host, kind, vmid)
        ticket = await client.term_ticket(node, kind, vmid)
        url = client.websocket_url(node, ticket["port"], ticket["ticket"], kind, vmid)

        import ssl as ssl_mod

        import websockets

        context = ssl_mod.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl_mod.CERT_NONE

        upstream = await websockets.connect(
            url, ssl=context, additional_headers=client.auth_header(),
            open_timeout=15, max_size=None,
        )
        # Proxmox attend « user:ticket\n » comme première trame.
        await upstream.send(f"{ticket['user']}:{ticket['ticket']}\n")
        await websocket.send_text(json.dumps({
            "t": "o", "d": f"\x1b[38;5;44m● Console {kind} {vmid} sur {node}\x1b[0m\r\n"}))
    except Exception as exc:  # noqa: BLE001
        await websocket.send_text(json.dumps({
            "t": "e", "d": f"\x1b[31m✖ {str(exc)[:400]}\x1b[0m\r\n"}))
        await websocket.close(code=4500)
        await client.close()
        return

    async def pump_down() -> None:
        try:
            async for message in upstream:
                text = message.decode("utf-8", "replace") if isinstance(message, bytes) else message
                await websocket.send_text(json.dumps({"t": "o", "d": text}))
        except Exception:  # noqa: BLE001
            pass

    async def pump_up() -> None:
        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    await upstream.send(raw)
                    continue
                if message.get("t") == "i":
                    # Protocole Proxmox : longueur puis contenu.
                    payload = message.get("d", "")
                    await upstream.send(f"0:{len(payload)}:{payload}")
                elif message.get("t") == "r":
                    await upstream.send(f"1:{message.get('cols', 120)}:{message.get('rows', 32)}:")
                elif message.get("t") == "ping":
                    await upstream.send("2")
        except Exception:  # noqa: BLE001
            pass

    tasks = [asyncio.create_task(pump_down()), asyncio.create_task(pump_up())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        with contextlib.suppress(Exception):
            await upstream.close()
        with contextlib.suppress(Exception):
            await websocket.close()
        await client.close()


# Tickets VNC en attente de leur WebSocket.
#
# Chaque appel à `vncproxy` démarre une *nouvelle* session VNC sur un nouveau
# port : demander un ticket pour le mot de passe RFB puis un second pour ouvrir
# le canal donnerait deux sessions distinctes, et le mot de passe ne
# correspondrait pas. Le ticket est donc créé une fois, remis au client pour la
# poignée de main, et consommé par le WebSocket qui suit.
_PENDING_VNC: dict[str, dict] = {}
VNC_TICKET_TTL = 60.0


def _sweep_vnc() -> None:
    now = time.monotonic()
    for key, entry in list(_PENDING_VNC.items()):
        if now - entry["created"] > VNC_TICKET_TTL:
            _PENDING_VNC.pop(key, None)


@router.get("/{host_id}/guests/{kind}/{vmid}/vnc")
async def vnc_info(host_id: int, kind: GuestKind, vmid: int,
                   user: dict = Depends(current_user)) -> dict:
    """Ticket VNC + lien noVNC natif, pour l'écran graphique d'une VM.

    Le mot de passe RFB *est* le ticket : le client noVNC embarqué dans MBA le
    présente pendant la poignée de main. Il ne vaut qu'une minute, pour ce seul
    invité, et pour une seule ouverture de canal.
    """
    host = await _require_pve(host_id)
    node = await _node_of(host, kind, vmid)
    client = await client_for_host(host)
    try:
        ticket = await client.vnc_ticket(node, kind, vmid)
        console = client.console_url(node, kind, vmid)
    except ProxmoxError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    finally:
        await client.close()

    _sweep_vnc()
    handle = secrets.token_urlsafe(12)
    _PENDING_VNC[handle] = {
        "host_id": host_id, "kind": kind, "vmid": vmid, "node": node,
        "ticket": ticket["ticket"], "port": ticket["port"],
        "created": time.monotonic(),
    }
    return {"node": node, "url": console, "password": ticket["ticket"], "handle": handle}


@router.websocket("/{host_id}/vnc/{kind}/{vmid}")
async def vnc_console(websocket: WebSocket, host_id: int, kind: str, vmid: int) -> None:
    """Relaie l'écran graphique (RFB) d'un invité jusqu'au client noVNC.

    Même raison que pour la console texte : le navigateur n'a ni le jeton d'API
    ni un certificat PVE accepté, et un iframe vers l'interface Proxmox se
    heurterait en plus à sa propre session. On relaie donc le flux RFB brut —
    en binaire, sans y toucher — et noVNC dessine dans un canvas de la page.
    """
    await websocket.accept(subprotocol="binary")
    try:
        await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return

    host = await fetch_one("SELECT * FROM hosts WHERE id = :id AND kind = 'proxmox'",
                           {"id": host_id})
    if not host:
        await websocket.close(code=4404)
        return

    # Le ticket doit être celui remis au client : c'est la même session VNC.
    _sweep_vnc()
    pending = _PENDING_VNC.pop(websocket.query_params.get("handle") or "", None)
    if not pending or pending["vmid"] != vmid or pending["host_id"] != host_id:
        log.warning("Console VNC %s/%s : ticket absent ou périmé", kind, vmid)
        await websocket.close(code=4401, reason="Ticket VNC expiré, rouvre la console")
        return

    client = await client_for_host(host)
    upstream = None
    try:
        node = pending["node"]
        url = client.websocket_url(node, pending["port"], pending["ticket"], kind, vmid)

        import ssl as ssl_mod

        import websockets

        context = ssl_mod.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl_mod.CERT_NONE

        upstream = await websockets.connect(
            url, ssl=context, additional_headers=client.auth_header(),
            subprotocols=["binary"], open_timeout=15, max_size=None,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("Console VNC %s/%s indisponible : %s", kind, vmid, exc)
        await websocket.close(code=4500, reason=str(exc)[:120])
        await client.close()
        return

    async def pump_down() -> None:
        try:
            async for message in upstream:
                if isinstance(message, str):
                    message = message.encode()
                await websocket.send_bytes(message)
        except Exception:  # noqa: BLE001
            pass

    async def pump_up() -> None:
        try:
            while True:
                message = await websocket.receive()
                if message.get("type") == "websocket.disconnect":
                    break
                data = message.get("bytes")
                if data is None and message.get("text") is not None:
                    data = message["text"].encode()
                if data:
                    await upstream.send(data)
        except Exception:  # noqa: BLE001
            pass

    tasks = [asyncio.create_task(pump_down()), asyncio.create_task(pump_up())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        with contextlib.suppress(Exception):
            await upstream.close()
        with contextlib.suppress(Exception):
            await websocket.close()
        await client.close()


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
