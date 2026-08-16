"""Terminal SSH interactif exposé en WebSocket (xterm.js côté navigateur).

Le shell lui-même vit dans `termsessions` : ce module ne fait que brancher un
navigateur sur une session, nouvelle ou déjà en cours.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging

from fastapi import APIRouter, Depends, HTTPException, Response, WebSocket, WebSocketDisconnect, status

from ..poller import log_event
from ..security import current_user, ws_user
from ..ssh import SSHError
from ..termsessions import TTL_CHOICES, resolve_host, store

log = logging.getLogger("mba.terminal")
router = APIRouter(tags=["terminal"])


@router.get("/terminal/sessions")
async def sessions(user: dict = Depends(current_user)) -> dict:
    """Sessions encore vivantes, pour restaurer les onglets à l'ouverture."""
    return {"sessions": store.list(), "ttl_choices": TTL_CHOICES}


@router.delete("/terminal/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def kill_session(session_id: str, user: dict = Depends(current_user)) -> Response:
    if not await store.close(session_id, "fermée par l'utilisateur"):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Session introuvable")
    return Response(status_code=204)


@router.websocket("/ws/terminal/{host_id}")
async def terminal(websocket: WebSocket, host_id: int) -> None:
    await websocket.accept()
    try:
        user = await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return

    params = websocket.query_params
    cols = int(params.get("cols") or 120)
    rows = int(params.get("rows") or 32)
    resume = params.get("session")

    session = store.get(resume) if resume else None
    fresh = session is None

    if session is None:
        try:
            host = await resolve_host(host_id)
        except SSHError as exc:
            await _send(websocket, "e", f"\x1b[31m✖ {exc}\x1b[0m\r\n")
            await websocket.close(code=4404)
            return

        container = params.get("container")
        label = host["name"] + (f" › {container}" if container else "")
        await _send(websocket, "o", f"\x1b[38;5;44m● Connexion à {label}…\x1b[0m\r\n")

        ttl = TTL_CHOICES.get(params.get("ttl") or "", None)
        if ttl is None:
            ttl = 0 if params.get("ttl") == "keep" else TTL_CHOICES["30m"]

        try:
            session = await store.create(host, container, user["username"], cols, rows, ttl)
        except SSHError as exc:
            await _send(websocket, "e", f"\x1b[31m✖ {exc}\x1b[0m\r\n")
            await websocket.close(code=4500)
            return
        except Exception as exc:  # noqa: BLE001
            await _send(websocket, "e", f"\x1b[31m✖ Ouverture du shell impossible : {exc}\x1b[0m\r\n")
            await websocket.close(code=4500)
            return

        await log_event(host_id, "info", "terminal",
                        f"Session terminal ouverte sur {label} par {user['username']}")

    # Le client doit connaître l'identifiant pour se rattacher plus tard.
    await _send_raw(websocket, {"t": "session", "id": session.id, "resumed": not fresh,
                                "label": session.label, "ttl": session.ttl})

    store.attach(session, websocket)
    if not fresh:
        # On rejoue ce qui a défilé pendant l'absence avant de reprendre le direct.
        if session.buffer:
            await _send(websocket, "o", session.buffer)
        await _send(websocket, "o",
                    "\r\n\x1b[38;5;44m● Session reprise\x1b[0m\r\n")
        store.resize(session, cols, rows)

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await store.write(session, raw)
                continue
            kind = message.get("t")
            if kind == "i":
                await store.write(session, message.get("d", ""))
            elif kind == "r":
                store.resize(session, int(message.get("cols", 120)), int(message.get("rows", 32)))
            elif kind == "ttl":
                session.ttl = TTL_CHOICES.get(message.get("value", ""), 0)
            elif kind == "ping":
                await _send(websocket, "pong", "")
    except (WebSocketDisconnect, RuntimeError, asyncio.CancelledError):
        pass
    finally:
        # On se détache sans tuer le shell : c'est tout l'intérêt.
        store.detach(session, websocket)
        with contextlib.suppress(Exception):
            await websocket.close()


async def _send(websocket: WebSocket, kind: str, data: str) -> None:
    await _send_raw(websocket, {"t": kind, "d": data})


async def _send_raw(websocket: WebSocket, message: dict) -> None:
    with contextlib.suppress(WebSocketDisconnect, RuntimeError):
        await websocket.send_text(json.dumps(message))
