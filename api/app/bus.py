from __future__ import annotations

import asyncio
import contextlib
import json
from collections import defaultdict, deque
from typing import Any

MAX_QUEUE = 200


class EventBus:
    """Pub/sub in-process + petit buffer circulaire pour le rendu instantané."""

    def __init__(self, buffer_size: int = 240) -> None:
        self._subs: set[asyncio.Queue] = set()
        self._buffers: dict[str, deque] = defaultdict(lambda: deque(maxlen=buffer_size))
        self._latest: dict[str, dict[str, Any]] = {}

    # ---------------------------------------------------------------- publish
    def publish(self, topic: str, payload: dict[str, Any]) -> None:
        message = {"topic": topic, "data": payload}
        # Le tampon circulaire ne sert qu'aux courbes, donc aux métriques ; le
        # dernier état, lui, vaut pour tous les topics : c'est ce que lisent les
        # vues de synthèse (IA, conteneurs…) au premier affichage, avant que le
        # flux temps réel ne prenne le relais.
        if topic.startswith("metrics."):
            self._buffers[topic].append(payload)
        self._latest[topic] = payload
        for queue in list(self._subs):
            if queue.qsize() >= MAX_QUEUE:
                with contextlib.suppress(asyncio.QueueEmpty):
                    queue.get_nowait()  # on jette le plus vieux, jamais de blocage
            with contextlib.suppress(asyncio.QueueFull):
                queue.put_nowait(message)

    # -------------------------------------------------------------- subscribe
    @contextlib.contextmanager
    def subscribe(self):
        queue: asyncio.Queue = asyncio.Queue(maxsize=MAX_QUEUE)
        self._subs.add(queue)
        try:
            yield queue
        finally:
            self._subs.discard(queue)

    # ------------------------------------------------------------------ state
    def history(self, topic: str) -> list[dict]:
        return list(self._buffers.get(topic, []))

    def latest(self, prefix: str = "") -> dict[str, dict]:
        return {k: v for k, v in self._latest.items() if k.startswith(prefix)}

    @staticmethod
    def dumps(message: dict) -> str:
        return json.dumps(message, default=str, separators=(",", ":"))


bus = EventBus()
