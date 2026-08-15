"""Terminal SSH interactif exposé en WebSocket (xterm.js côté navigateur)."""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import shlex

import asyncssh
from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..db import fetch_one
from ..poller import log_event
from ..security import ws_user
from ..ssh import SSHError, pool

log = logging.getLogger("mba.terminal")
router = APIRouter(tags=["terminal"])


@router.websocket("/ws/terminal/{host_id}")
async def terminal(websocket: WebSocket, host_id: int) -> None:
    await websocket.accept()
    try:
        user = await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return

    host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    if not host:
        await _send(websocket, "e", "Hôte introuvable\r\n")
        await websocket.close(code=4404)
        return
    if host["kind"] not in ("linux", "docker", "proxmox"):
        await _send(websocket, "e", f"Terminal indisponible pour un hôte « {host['kind']} »\r\n")
        await websocket.close(code=4400)
        return

    container = websocket.query_params.get("container")
    cols = int(websocket.query_params.get("cols") or 120)
    rows = int(websocket.query_params.get("rows") or 32)

    label = f"{host['name']}" + (f" › {container}" if container else "")
    await _send(websocket, "o", f"\x1b[38;5;44m● Connexion à {label}…\x1b[0m\r\n")

    try:
        conn = await pool.get(host)
    except SSHError as exc:
        await _send(websocket, "e", f"\x1b[31m✖ {exc}\x1b[0m\r\n")
        await websocket.close(code=4500)
        return

    command = None
    if container:
        safe = shlex.quote(container)
        command = (f"docker exec -it {safe} sh -c "
                   f"'command -v bash >/dev/null 2>&1 && exec bash || exec sh'")

    try:
        process = await conn.create_process(
            command,
            term_type="xterm-256color",
            term_size=(cols, rows),
            encoding="utf-8",
            stderr=asyncssh.STDOUT,
        )
    except (asyncssh.Error, OSError) as exc:
        await _send(websocket, "e", f"\x1b[31m✖ Ouverture du shell impossible : {exc}\x1b[0m\r\n")
        await websocket.close(code=4500)
        return

    await log_event(host_id, "info", "terminal",
                    f"Session terminal ouverte sur {label} par {user['username']}")

    async def pump_out() -> None:
        try:
            while True:
                data = await process.stdout.read(4096)
                if not data:
                    break
                await _send(websocket, "o", data)
        except (asyncssh.Error, WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
            pass

    async def pump_in() -> None:
        try:
            while True:
                raw = await websocket.receive_text()
                try:
                    message = json.loads(raw)
                except json.JSONDecodeError:
                    process.stdin.write(raw)
                    continue
                kind = message.get("t")
                if kind == "i":
                    process.stdin.write(message.get("d", ""))
                elif kind == "r":
                    with contextlib.suppress(asyncssh.Error):
                        process.change_terminal_size(int(message.get("cols", 120)),
                                                     int(message.get("rows", 32)))
                elif kind == "ping":
                    await _send(websocket, "pong", "")
        except (WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
            pass

    tasks = [asyncio.create_task(pump_out()), asyncio.create_task(pump_in())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        with contextlib.suppress(Exception):
            process.close()
        with contextlib.suppress(Exception):
            await websocket.close()
        log.info("Session terminal fermée: %s", label)


async def _send(websocket: WebSocket, kind: str, data: str) -> None:
    with contextlib.suppress(WebSocketDisconnect, RuntimeError):
        await websocket.send_text(json.dumps({"t": kind, "d": data}))
