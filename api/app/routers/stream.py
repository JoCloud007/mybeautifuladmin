"""Flux temps réel unique : métriques, évènements, alertes, services, actions."""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..bus import bus
from ..security import ws_user

log = logging.getLogger("mba.stream")
router = APIRouter(tags=["stream"])

HEARTBEAT = 20.0


@router.websocket("/ws/stream")
async def stream(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        await ws_user(websocket, websocket.query_params.get("token"))
    except Exception:  # noqa: BLE001
        return

    # Filtre optionnel : ?topics=metrics.3,event  (préfixes)
    raw_topics = websocket.query_params.get("topics") or ""
    prefixes = tuple(t.strip() for t in raw_topics.split(",") if t.strip())

    def wanted(topic: str) -> bool:
        return not prefixes or topic.startswith(prefixes)

    # Snapshot immédiat : l'UI s'affiche remplie, sans attendre le prochain cycle.
    snapshot = {topic: data for topic, data in bus.latest().items() if wanted(topic)}
    with contextlib.suppress(WebSocketDisconnect, RuntimeError):
        await websocket.send_text(json.dumps({"topic": "snapshot", "data": snapshot}, default=str))

    with bus.subscribe() as queue:
        async def forward() -> None:
            while True:
                message = await queue.get()
                if wanted(message["topic"]):
                    await websocket.send_text(bus.dumps(message))

        async def heartbeat() -> None:
            while True:
                await asyncio.sleep(HEARTBEAT)
                await websocket.send_text('{"topic":"ping","data":{}}')

        async def drain() -> None:
            # On lit le canal client pour détecter proprement la déconnexion.
            while True:
                await websocket.receive_text()

        tasks = [asyncio.create_task(c()) for c in (forward, heartbeat, drain)]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            with contextlib.suppress(Exception):
                await websocket.close()
