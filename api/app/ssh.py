from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

import asyncssh

from .db import fetch_one
from .vault import decrypt

log = logging.getLogger("mba.ssh")
asyncssh.set_log_level(logging.WARNING)


class SSHError(RuntimeError):
    pass


@dataclass(slots=True)
class SSHTarget:
    host: str
    port: int
    username: str
    password: str | None = None
    private_key: str | None = None
    passphrase: str | None = None

    def options(self) -> dict:
        opts: dict = {
            "username": self.username,
            "known_hosts": None,          # infra perso : on ne valide pas le host key
            "connect_timeout": 8,
            "login_timeout": 10,
            "keepalive_interval": 30,
        }
        if self.private_key:
            key = asyncssh.import_private_key(self.private_key, passphrase=self.passphrase or None)
            opts["client_keys"] = [key]
        if self.password:
            opts["password"] = self.password
        return opts


async def target_for_host(host: dict) -> SSHTarget:
    """Construit la cible SSH d'un hôte à partir de son credential déchiffré."""
    cred_id = host.get("credential_id")
    if not cred_id:
        raise SSHError(f"Aucun credential associé à « {host['name']} »")
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
    if not cred:
        raise SSHError("Credential introuvable")

    secret = decrypt(cred["secret_enc"])
    passphrase = decrypt(cred["passphrase_enc"])
    if cred["kind"] not in ("ssh_password", "ssh_key"):
        raise SSHError(f"Le credential « {cred['name']} » n'est pas utilisable en SSH")

    return SSHTarget(
        host=host["address"],
        port=host.get("port") or 22,
        username=cred["username"] or "root",
        password=secret if cred["kind"] == "ssh_password" else None,
        private_key=secret if cred["kind"] == "ssh_key" else None,
        passphrase=passphrase,
    )


class SSHPool:
    """Connexions SSH persistantes, une par hôte, réutilisées par les collecteurs."""

    def __init__(self) -> None:
        self._conns: dict[int, asyncssh.SSHClientConnection] = {}
        self._locks: dict[int, asyncio.Lock] = {}

    def _lock(self, host_id: int) -> asyncio.Lock:
        return self._locks.setdefault(host_id, asyncio.Lock())

    async def get(self, host: dict) -> asyncssh.SSHClientConnection:
        hid = host["id"]
        conn = self._conns.get(hid)
        if conn is not None and not conn.is_closed():
            return conn
        async with self._lock(hid):
            conn = self._conns.get(hid)
            if conn is not None and not conn.is_closed():
                return conn
            target = await target_for_host(host)
            try:
                conn = await asyncio.wait_for(
                    asyncssh.connect(target.host, port=target.port, **target.options()),
                    timeout=15,
                )
            except Exception as exc:  # noqa: BLE001
                raise SSHError(str(exc)) from exc
            self._conns[hid] = conn
            return conn

    async def run(self, host: dict, command: str, timeout: float = 20.0) -> str:
        conn = await self.get(host)
        try:
            result = await asyncio.wait_for(conn.run(command, check=False), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise SSHError(f"Timeout sur « {command[:60]} »") from exc
        except (asyncssh.Error, OSError) as exc:
            self.drop(host["id"])
            raise SSHError(str(exc)) from exc
        return (result.stdout or "") + (result.stderr or "" if result.exit_status else "")

    async def run_status(self, host: dict, command: str, timeout: float = 60.0) -> tuple[int, str, str]:
        conn = await self.get(host)
        try:
            res = await asyncio.wait_for(conn.run(command, check=False), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise SSHError(f"Timeout sur « {command[:60]} »") from exc
        return res.exit_status or 0, res.stdout or "", res.stderr or ""

    def drop(self, host_id: int) -> None:
        conn = self._conns.pop(host_id, None)
        if conn is not None:
            conn.close()

    async def close(self) -> None:
        for conn in self._conns.values():
            conn.close()
        self._conns.clear()


pool = SSHPool()
