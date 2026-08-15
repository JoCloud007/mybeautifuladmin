"""Client Proxmox Backup Server.

Le PBS expose la même API que PVE, sur le port 8007, avec son propre schéma de
jeton (`PBSAPIToken`). On en tire l'inventaire des sauvegardes, leur fraîcheur et
leur état de vérification — la matière première de l'analyse des risques.
"""
from __future__ import annotations

import datetime as dt
import logging
from typing import Any

import httpx

from ..db import fetch_one
from ..vault import decrypt

log = logging.getLogger("mba.pbs")


class PBSError(RuntimeError):
    pass


class PBSClient:
    def __init__(self, address: str, port: int = 8007, token: str | None = None,
                 username: str | None = None, password: str | None = None) -> None:
        self.base = f"https://{address}:{port}/api2/json"
        self.token = token
        self.username = username
        self.password = password
        self._ticket: str | None = None
        self._client = httpx.AsyncClient(verify=False, timeout=25.0)

    async def _headers(self) -> dict[str, str]:
        if self.token:
            # Format attendu : user@pbs!tokenid:secret
            return {"Authorization": f"PBSAPIToken={self.token}"}
        if not self._ticket:
            if not self.username or not self.password:
                raise PBSError("Identifiants PBS manquants (jeton d'API ou user/mot de passe)")
            resp = await self._client.post(
                f"{self.base}/access/ticket",
                data={"username": self.username, "password": self.password},
            )
            if resp.status_code != 200:
                raise PBSError(f"Authentification PBS refusée ({resp.status_code})")
            self._ticket = resp.json()["data"]["ticket"]
        return {"Cookie": f"PBSAuthCookie={self._ticket}"}

    async def get(self, path: str) -> Any:
        resp = await self._client.get(f"{self.base}{path}", headers=await self._headers())
        if resp.status_code == 401:
            self._ticket = None
            resp = await self._client.get(f"{self.base}{path}", headers=await self._headers())
        if resp.status_code == 403:
            raise PBSError(f"Accès refusé sur {path} — vérifie les droits du jeton")
        if resp.status_code >= 400:
            raise PBSError(f"GET {path} → {resp.status_code} {resp.text[:180]}")
        return resp.json().get("data")

    async def close(self) -> None:
        await self._client.aclose()

    # ---------------------------------------------------------------- lecture
    async def datastores(self) -> list[dict]:
        usage = await self.get("/status/datastore-usage") or []
        out = []
        for store in usage:
            total = store.get("total") or 0
            used = store.get("used") or 0
            out.append({
                "name": store.get("store"),
                "total": total,
                "used": used,
                "available": store.get("avail") or max(0, total - used),
                "percent": round(100.0 * used / total, 2) if total else 0.0,
                # PBS estime la date de saturation à partir de la tendance récente.
                "estimated_full": store.get("estimated-full-date"),
                "history": store.get("history") or [],
            })
        return out

    async def snapshots(self, store: str) -> list[dict]:
        raw = await self.get(f"/admin/datastore/{store}/snapshots") or []
        out = []
        for snap in raw:
            verification = snap.get("verification") or {}
            out.append({
                "store": store,
                "backup_type": snap.get("backup-type"),
                "backup_id": snap.get("backup-id"),
                "time": snap.get("backup-time"),
                "size": snap.get("size") or 0,
                "owner": snap.get("owner"),
                "protected": bool(snap.get("protected")),
                "verified": verification.get("state"),
                "verified_at": verification.get("upid"),
                "comment": snap.get("comment"),
                "files": len(snap.get("files") or []),
            })
        out.sort(key=lambda s: s["time"] or 0, reverse=True)
        return out

    async def groups(self, store: str) -> list[dict]:
        raw = await self.get(f"/admin/datastore/{store}/groups") or []
        return [{
            "store": store,
            "backup_type": g.get("backup-type"),
            "backup_id": g.get("backup-id"),
            "count": g.get("backup-count") or 0,
            "last_backup": g.get("last-backup"),
            "owner": g.get("owner"),
            "comment": g.get("comment"),
            "files": g.get("files") or [],
        } for g in raw]

    async def tasks(self, limit: int = 50) -> list[dict]:
        try:
            raw = await self.get(f"/nodes/localhost/tasks?limit={limit}&errors=1") or []
        except PBSError:
            return []
        return [{
            "upid": t.get("upid"),
            "type": t.get("worker_type"),
            "target": t.get("worker_id"),
            "user": t.get("user"),
            "status": t.get("status") or ("running" if not t.get("endtime") else "OK"),
            "started": t.get("starttime"),
            "ended": t.get("endtime"),
        } for t in raw]

    async def snapshot(self) -> dict[str, Any]:
        """Vue consolidée d'un PBS : stockages, groupes, tâches."""
        stores = await self.datastores()
        groups: list[dict] = []
        for store in stores:
            try:
                groups.extend(await self.groups(store["name"]))
            except PBSError as exc:
                log.debug("Groupes illisibles sur %s : %s", store["name"], exc)
        tasks = await self.tasks()

        failed = [t for t in tasks
                  if t["status"] not in ("OK", "running") and t["status"] is not None]
        metrics = {
            "pbs.datastores": float(len(stores)),
            "pbs.groups": float(len(groups)),
            "pbs.tasks_failed": float(len(failed)),
        }
        for store in stores:
            metrics[f"pbs.usage.{store['name']}"] = store["percent"]
        if stores:
            metrics["disk.percent"] = max(s["percent"] for s in stores)
            metrics["disk.total"] = sum(s["total"] for s in stores)
            metrics["disk.used"] = sum(s["used"] for s in stores)

        return {
            "metrics": metrics,
            "datastores": stores,
            "groups": groups,
            "tasks": tasks[:30],
        }


async def client_for_host(host: dict) -> PBSClient:
    cred_id = host.get("credential_id")
    token = username = password = None
    if cred_id:
        cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
        if cred:
            secret = decrypt(cred["secret_enc"])
            if cred["kind"] in ("api_token", "token"):
                # Accepte « user@pbs!id:secret » complet ou l'identifiant séparé.
                token = secret if ":" in (secret or "") else f"{cred['username']}:{secret}"
            else:
                username, password = cred["username"], secret
    return PBSClient(host["address"], host.get("port") or 8007, token, username, password)
