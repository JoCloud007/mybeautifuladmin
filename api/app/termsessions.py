"""Sessions terminal persistantes.

Un shell ouvert depuis MBA ne doit pas mourir parce qu'on a changé de page,
verrouillé l'écran ou perdu le Wi-Fi trente secondes. Le processus SSH vit donc
côté API, indépendamment de tout navigateur : une boucle lit sa sortie en
continu, la conserve dans un tampon circulaire et la diffuse aux clients
attachés. Se reconnecter, c'est se rattacher à une session déjà vivante et
recevoir d'abord ce qu'on a manqué.

Trois bornes évitent qu'un shell oublié ne vive éternellement : un TTL d'inactivité
par session, un plafond de sessions simultanées, et la fermeture immédiate dès
que le shell distant rend la main.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import shlex
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import asyncssh

from .db import fetch_one
from .ssh import SSHError, pool

log = logging.getLogger("mba.term")

# Ce qu'on garde de la sortie d'un shell détaché, en caractères. Assez pour
# retrouver le contexte d'un `make` ou d'un `journalctl -f` au retour.
SCROLLBACK = 256 * 1024

# Durées de rétention proposées à l'utilisateur, en secondes.
TTL_CHOICES: dict[str, int] = {
    "5m": 300,
    "30m": 1800,
    "2h": 7200,
    "8h": 28800,
    "24h": 86400,
}
DEFAULT_TTL = 1800
MAX_SESSIONS = 24


@dataclass
class TermSession:
    id: str
    host_id: int
    host_name: str
    container: str | None
    owner: str
    ttl: int
    process: Any
    cols: int = 120
    rows: int = 32
    created: float = field(default_factory=time.time)
    detached_since: float | None = field(default_factory=time.time)
    buffer: str = ""
    clients: set = field(default_factory=set)
    pump: asyncio.Task | None = None
    closed: bool = False
    exit_reason: str | None = None

    @property
    def label(self) -> str:
        return self.host_name + (f" › {self.container}" if self.container else "")

    def public(self) -> dict:
        return {
            "id": self.id,
            "host_id": self.host_id,
            "host_name": self.host_name,
            "container": self.container,
            "label": self.label,
            "owner": self.owner,
            "ttl": self.ttl,
            "created": self.created,
            "attached": len(self.clients),
            "detached_since": self.detached_since,
            "buffered": len(self.buffer),
            "closed": self.closed,
            "exit_reason": self.exit_reason,
        }


class SessionStore:
    def __init__(self) -> None:
        self._sessions: dict[str, TermSession] = {}
        self._reaper: asyncio.Task | None = None

    # ------------------------------------------------------------------ cycle
    async def create(self, host: dict, container: str | None, owner: str,
                     cols: int, rows: int, ttl: int) -> TermSession:
        if len(self._sessions) >= MAX_SESSIONS:
            self._drop_oldest_detached()
        if len(self._sessions) >= MAX_SESSIONS:
            raise SSHError(
                f"{MAX_SESSIONS} sessions déjà ouvertes. Ferme-en une avant d'en ouvrir une autre."
            )

        conn = await pool.get(host)
        command = None
        if container:
            safe = shlex.quote(container)
            command = (f"docker exec -it {safe} sh -c "
                       f"'command -v bash >/dev/null 2>&1 && exec bash || exec sh'")
        process = await conn.create_process(
            command,
            term_type="xterm-256color",
            term_size=(cols, rows),
            encoding="utf-8",
            stderr=asyncssh.STDOUT,
        )

        session = TermSession(
            id=uuid.uuid4().hex[:12],
            host_id=host["id"],
            host_name=host["name"],
            container=container,
            owner=owner,
            ttl=ttl,
            process=process,
            cols=cols,
            rows=rows,
        )
        self._sessions[session.id] = session
        session.pump = asyncio.create_task(self._pump(session), name=f"term-{session.id}")
        self._ensure_reaper()
        log.info("Session terminal %s ouverte sur %s", session.id, session.label)
        return session

    def get(self, session_id: str) -> TermSession | None:
        return self._sessions.get(session_id)

    def list(self, owner: str | None = None) -> list[dict]:
        return [s.public() for s in self._sessions.values()
                if owner is None or s.owner == owner]

    async def close(self, session_id: str, reason: str = "fermée") -> bool:
        session = self._sessions.pop(session_id, None)
        if not session:
            return False
        session.closed = True
        session.exit_reason = reason
        if session.pump:
            session.pump.cancel()
        with contextlib.suppress(Exception):
            session.process.close()
        for client in list(session.clients):
            with contextlib.suppress(Exception):
                await client.close(code=4000)
        session.clients.clear()
        log.info("Session terminal %s %s", session_id, reason)
        return True

    async def close_all(self) -> None:
        for session_id in list(self._sessions):
            await self.close(session_id, "arrêt du serveur")

    # --------------------------------------------------------------- attaches
    def attach(self, session: TermSession, websocket) -> None:
        session.clients.add(websocket)
        session.detached_since = None

    def detach(self, session: TermSession, websocket) -> None:
        session.clients.discard(websocket)
        if not session.clients:
            session.detached_since = time.time()

    async def write(self, session: TermSession, data: str) -> None:
        with contextlib.suppress(Exception):
            session.process.stdin.write(data)

    def resize(self, session: TermSession, cols: int, rows: int) -> None:
        # Deux clients sur la même session imposeraient des tailles concurrentes ;
        # le dernier arrivé fait foi, comme dans un tmux partagé.
        session.cols, session.rows = cols, rows
        with contextlib.suppress(asyncssh.Error, Exception):
            session.process.change_terminal_size(cols, rows)

    # --------------------------------------------------------------- internes
    async def _pump(self, session: TermSession) -> None:
        """Lit la sortie du shell en continu, même sans client attaché."""
        try:
            while True:
                data = await session.process.stdout.read(4096)
                if not data:
                    break
                session.buffer = (session.buffer + data)[-SCROLLBACK:]
                await self._broadcast(session, {"t": "o", "d": data})
        except (asyncssh.Error, asyncio.CancelledError, RuntimeError):
            pass
        finally:
            if not session.closed:
                await self._broadcast(
                    session, {"t": "e", "d": "\r\n\x1b[38;5;244m── shell terminé ──\x1b[0m\r\n"})
                await self.close(session.id, "shell terminé")

    async def _broadcast(self, session: TermSession, message: dict) -> None:
        payload = json.dumps(message)
        for client in list(session.clients):
            try:
                await client.send_text(payload)
            except Exception:  # noqa: BLE001 — client parti en cours de route
                session.clients.discard(client)
        if not session.clients and session.detached_since is None:
            session.detached_since = time.time()

    def _drop_oldest_detached(self) -> None:
        detached = [s for s in self._sessions.values() if s.detached_since]
        if detached:
            oldest = min(detached, key=lambda s: s.detached_since or 0)
            asyncio.create_task(self.close(oldest.id, "évincée (trop de sessions)"))

    def _ensure_reaper(self) -> None:
        if self._reaper is None or self._reaper.done():
            self._reaper = asyncio.create_task(self._reap(), name="term-reaper")

    async def _reap(self) -> None:
        """Ferme les sessions détachées depuis plus longtemps que leur TTL."""
        while self._sessions:
            await asyncio.sleep(30)
            now = time.time()
            for session in list(self._sessions.values()):
                if session.ttl <= 0 or not session.detached_since:
                    continue  # 0 = garder jusqu'à fermeture explicite
                if now - session.detached_since > session.ttl:
                    await self.close(session.id, "expirée (inactive)")


store = SessionStore()


async def resolve_host(host_id: int) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    if not host:
        raise SSHError("Hôte introuvable")
    if host["kind"] not in ("linux", "docker", "proxmox"):
        raise SSHError(f"Terminal indisponible pour un hôte « {host['kind']} »")
    return host
