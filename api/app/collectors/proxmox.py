"""Client Proxmox VE (API HTTP)."""
from __future__ import annotations

import logging
from typing import Any

import httpx

from ..db import fetch_one
from ..vault import decrypt

log = logging.getLogger("mba.proxmox")


class ProxmoxError(RuntimeError):
    pass


TOKEN_HELP = (
    "Proxmox a refusé l'authentification (401).\n\n"
    "Crée le jeton ainsi :\n"
    "1. Datacenter → Permissions → API Tokens → Add\n"
    "2. User : root@pam (ou un utilisateur dédié), Token ID : mba\n"
    "3. DÉCOCHE « Privilege Separation » — sinon le jeton n'hérite d'aucun droit\n"
    "4. Copie le secret affiché une seule fois\n\n"
    "Dans MBA (Réglages → Identifiants), type « Jeton d'API » :\n"
    "  · Utilisateur : root@pam!mba      (identifiant complet du jeton)\n"
    "  · Secret : le UUID copié\n\n"
    "Tu peux aussi tout mettre dans le secret : root@pam!mba=<uuid>.\n"
    "Si tu as laissé « Privilege Separation » cochée, ajoute une permission : "
    "Datacenter → Permissions → Add → API Token Permission, path /, rôle PVEAdmin."
)

PERMISSION_HELP = (
    "Le jeton est reconnu mais n'a pas les droits nécessaires (403).\n"
    "Ajoute-lui le rôle PVEAdmin sur le chemin « / » dans "
    "Datacenter → Permissions → API Token Permission."
)


class ProxmoxClient:
    def __init__(self, address: str, port: int, token: str | None = None,
                 username: str | None = None, password: str | None = None) -> None:
        self.base = f"https://{address}:{port or 8006}/api2/json"
        self.token = token
        self.username = username
        self.password = password
        self._ticket: str | None = None
        self._csrf: str | None = None
        self._client = httpx.AsyncClient(verify=False, timeout=15.0)

    # -------------------------------------------------------------------- auth
    async def _headers(self, write: bool = False) -> dict[str, str]:
        if self.token:
            # Format attendu : user@realm!tokenid=uuid
            return {"Authorization": f"PVEAPIToken={self.token}"}
        if not self._ticket:
            await self._login()
        headers = {"Cookie": f"PVEAuthCookie={self._ticket}"}
        if write and self._csrf:
            headers["CSRFPreventionToken"] = self._csrf
        return headers

    async def _login(self) -> None:
        if not self.username or not self.password:
            raise ProxmoxError("Identifiants Proxmox manquants (token API ou user/mot de passe)")
        resp = await self._client.post(
            f"{self.base}/access/ticket",
            data={"username": self.username, "password": self.password},
        )
        if resp.status_code != 200:
            raise ProxmoxError(f"Authentification refusée ({resp.status_code})")
        data = resp.json()["data"]
        self._ticket = data["ticket"]
        self._csrf = data["CSRFPreventionToken"]

    # ------------------------------------------------------------------ verbes
    def _raise(self, method: str, path: str, resp: httpx.Response) -> None:
        """Traduit les codes d'erreur Proxmox en instructions actionnables."""
        if resp.status_code == 401:
            raise ProxmoxError(TOKEN_HELP if self.token else
                               "Identifiants Proxmox refusés (401) : vérifie le couple "
                               "utilisateur/mot de passe et le royaume (@pam, @pve).")
        if resp.status_code == 403:
            raise ProxmoxError(PERMISSION_HELP)
        if resp.status_code == 596 or resp.status_code == 595:
            raise ProxmoxError("Le nœud Proxmox ne répond pas (erreur de cluster). "
                               "Vérifie que le service pvedaemon tourne.")
        raise ProxmoxError(f"{method} {path} → {resp.status_code} {resp.text[:200]}")

    async def get(self, path: str) -> Any:
        resp = await self._client.get(f"{self.base}{path}", headers=await self._headers())
        # Un ticket expiré se rejoue une fois ; un jeton refusé ne se rejoue pas.
        if resp.status_code == 401 and not self.token:
            self._ticket = None
            resp = await self._client.get(f"{self.base}{path}", headers=await self._headers())
        if resp.status_code >= 400:
            self._raise("GET", path, resp)
        return resp.json().get("data")

    async def post(self, path: str, data: dict | None = None) -> Any:
        resp = await self._client.post(
            f"{self.base}{path}", headers=await self._headers(write=True), data=data or {}
        )
        if resp.status_code >= 400:
            self._raise("POST", path, resp)
        return resp.json().get("data")

    async def close(self) -> None:
        await self._client.aclose()

    # -------------------------------------------------------------- collecteur
    async def snapshot(self) -> dict[str, Any]:
        """État complet du cluster/nœud en un appel logique."""
        nodes = await self.get("/nodes") or []
        resources = await self.get("/cluster/resources") or []

        guests, storages = [], []
        for res in resources:
            if res.get("type") in ("qemu", "lxc"):
                maxmem = res.get("maxmem") or 0
                guests.append({
                    "vmid": res.get("vmid"),
                    "name": res.get("name") or f"{res.get('type')}-{res.get('vmid')}",
                    "type": res.get("type"),
                    "node": res.get("node"),
                    "status": res.get("status"),
                    "cpu": round(100.0 * (res.get("cpu") or 0.0), 2),
                    "maxcpu": res.get("maxcpu"),
                    "mem": res.get("mem") or 0,
                    "maxmem": maxmem,
                    "mem_percent": round(100.0 * (res.get("mem") or 0) / maxmem, 2) if maxmem else 0.0,
                    "disk": res.get("disk") or 0,
                    "maxdisk": res.get("maxdisk") or 0,
                    "uptime": res.get("uptime") or 0,
                    "tags": (res.get("tags") or "").split(";") if res.get("tags") else [],
                })
            elif res.get("type") == "storage":
                total = res.get("maxdisk") or 0
                storages.append({
                    "name": res.get("storage"),
                    "node": res.get("node"),
                    "used": res.get("disk") or 0,
                    "total": total,
                    "percent": round(100.0 * (res.get("disk") or 0) / total, 2) if total else 0.0,
                    "status": res.get("status"),
                })

        node_stats = []
        metrics: dict[str, Any] = {}
        for node in nodes:
            name = node.get("node")
            try:
                status = await self.get(f"/nodes/{name}/status") or {}
            except ProxmoxError:
                status = {}
            mem = status.get("memory") or {}
            root = status.get("rootfs") or {}
            cpu_pct = round(100.0 * (node.get("cpu") or status.get("cpu") or 0.0), 2)
            entry = {
                "node": name,
                "status": node.get("status"),
                "cpu": cpu_pct,
                "cpu_count": (status.get("cpuinfo") or {}).get("cpus"),
                "cpu_model": (status.get("cpuinfo") or {}).get("model"),
                "mem_used": mem.get("used", node.get("mem", 0)),
                "mem_total": mem.get("total", node.get("maxmem", 0)),
                "disk_used": root.get("used", 0),
                "disk_total": root.get("total", 0),
                "uptime": status.get("uptime", node.get("uptime", 0)),
                "loadavg": status.get("loadavg", []),
                "version": (status.get("pveversion") or node.get("pveversion") or ""),
            }
            node_stats.append(entry)
            metrics[f"pve.node.cpu.{name}"] = cpu_pct
            if entry["mem_total"]:
                metrics[f"pve.node.mem.{name}"] = round(100.0 * entry["mem_used"] / entry["mem_total"], 2)

        running = [g for g in guests if g["status"] == "running"]
        primary = node_stats[0] if node_stats else {}
        metrics.update({
            "cpu.usage": primary.get("cpu", 0.0),
            "mem.percent": round(100.0 * primary["mem_used"] / primary["mem_total"], 2)
            if primary.get("mem_total") else 0.0,
            "mem.used": primary.get("mem_used", 0),
            "mem.total": primary.get("mem_total", 0),
            "disk.percent": round(100.0 * primary["disk_used"] / primary["disk_total"], 2)
            if primary.get("disk_total") else 0.0,
            "uptime": primary.get("uptime", 0),
            "load.1": (primary.get("loadavg") or [0])[0] if primary.get("loadavg") else 0,
            "pve.guests.total": len(guests),
            "pve.guests.running": len(running),
        })

        return {
            "metrics": metrics,
            "nodes": node_stats,
            "guests": guests,
            "storages": storages,
        }

    # ------------------------------------------------------------------ actions
    async def guest_action(self, node: str, kind: str, vmid: int, action: str) -> Any:
        allowed = {"start", "stop", "shutdown", "reboot", "suspend", "resume", "reset"}
        if action not in allowed:
            raise ProxmoxError(f"Action inconnue: {action}")
        return await self.post(f"/nodes/{node}/{kind}/{vmid}/status/{action}")

    async def node_action(self, node: str, action: str) -> Any:
        if action not in ("reboot", "shutdown"):
            raise ProxmoxError(f"Action nœud inconnue: {action}")
        return await self.post(f"/nodes/{node}/status", {"command": action})

    # ------------------------------------------------------ administration VM
    async def guest_config(self, node: str, kind: str, vmid: int) -> dict:
        return await self.get(f"/nodes/{node}/{kind}/{vmid}/config") or {}

    async def set_guest_config(self, node: str, kind: str, vmid: int, payload: dict) -> Any:
        """Modifie la configuration (cœurs, mémoire, description, démarrage auto)."""
        allowed = {"cores", "sockets", "memory", "balloon", "name", "hostname",
                   "description", "onboot", "tags", "cpulimit", "cpuunits"}
        clean = {k: v for k, v in payload.items() if k in allowed and v is not None}
        if not clean:
            raise ProxmoxError("Aucun paramètre modifiable fourni")
        # PUT sur QEMU, POST sur LXC : l'API Proxmox n'est pas homogène.
        path = f"/nodes/{node}/{kind}/{vmid}/config"
        if kind == "qemu":
            resp = await self._client.put(f"{self.base}{path}",
                                          headers=await self._headers(write=True), data=clean)
            if resp.status_code >= 400:
                raise ProxmoxError(f"PUT {path} → {resp.status_code} {resp.text[:200]}")
            return resp.json().get("data")
        return await self.post(path, clean)

    async def snapshots(self, node: str, kind: str, vmid: int) -> list[dict]:
        data = await self.get(f"/nodes/{node}/{kind}/{vmid}/snapshot") or []
        return [{
            "name": s.get("name"),
            "description": s.get("description", "").strip(),
            "created": s.get("snaptime"),
            "parent": s.get("parent"),
            "vmstate": bool(s.get("vmstate")),
            # « current » est un pseudo-snapshot qui représente l'état vivant.
            "current": s.get("name") == "current",
        } for s in data]

    async def create_snapshot(self, node: str, kind: str, vmid: int, name: str,
                              description: str = "", vmstate: bool = False) -> Any:
        payload: dict[str, Any] = {"snapname": name, "description": description}
        if kind == "qemu" and vmstate:
            payload["vmstate"] = 1
        return await self.post(f"/nodes/{node}/{kind}/{vmid}/snapshot", payload)

    async def delete_snapshot(self, node: str, kind: str, vmid: int, name: str) -> Any:
        resp = await self._client.delete(
            f"{self.base}/nodes/{node}/{kind}/{vmid}/snapshot/{name}",
            headers=await self._headers(write=True),
        )
        if resp.status_code >= 400:
            raise ProxmoxError(f"Suppression du snapshot → {resp.status_code} {resp.text[:200]}")
        return resp.json().get("data")

    async def rollback_snapshot(self, node: str, kind: str, vmid: int, name: str) -> Any:
        return await self.post(f"/nodes/{node}/{kind}/{vmid}/snapshot/{name}/rollback")

    async def clone(self, node: str, kind: str, vmid: int, newid: int, name: str,
                    full: bool = True, target: str | None = None) -> Any:
        payload: dict[str, Any] = {"newid": newid, "full": 1 if full else 0}
        payload["name" if kind == "qemu" else "hostname"] = name
        if target:
            payload["target"] = target
        return await self.post(f"/nodes/{node}/{kind}/{vmid}/clone", payload)

    async def migrate(self, node: str, kind: str, vmid: int, target: str,
                      online: bool = True, with_local_disks: bool = False) -> Any:
        payload: dict[str, Any] = {"target": target}
        if online:
            payload["online" if kind == "qemu" else "restart"] = 1
        if with_local_disks and kind == "qemu":
            payload["with-local-disks"] = 1
        return await self.post(f"/nodes/{node}/{kind}/{vmid}/migrate", payload)

    async def backup(self, node: str, vmid: int, storage: str, mode: str = "snapshot",
                     compress: str = "zstd", notes: str = "") -> Any:
        payload: dict[str, Any] = {
            "vmid": vmid, "storage": storage, "mode": mode,
            "compress": compress, "remove": 0,
        }
        if notes:
            payload["notes-template"] = notes
        return await self.post(f"/nodes/{node}/vzdump", payload)

    async def backups(self, node: str, vmid: int | None = None) -> list[dict]:
        """Sauvegardes présentes sur les stockages du nœud."""
        storages = await self.get(f"/nodes/{node}/storage") or []
        out = []
        for storage in storages:
            if "backup" not in (storage.get("content") or ""):
                continue
            try:
                content = await self.get(
                    f"/nodes/{node}/storage/{storage['storage']}/content?content=backup"
                ) or []
            except ProxmoxError:
                continue
            for item in content:
                if vmid and item.get("vmid") != vmid:
                    continue
                out.append({
                    "volid": item.get("volid"),
                    "storage": storage["storage"],
                    "vmid": item.get("vmid"),
                    "size": item.get("size"),
                    "created": item.get("ctime"),
                    "format": item.get("format"),
                    "notes": item.get("notes"),
                    "protected": bool(item.get("protected")),
                })
        out.sort(key=lambda b: b.get("created") or 0, reverse=True)
        return out

    async def backup_storages(self, node: str) -> list[dict]:
        storages = await self.get(f"/nodes/{node}/storage") or []
        return [{
            "name": s["storage"],
            "type": s.get("type"),
            "available": s.get("avail"),
            "total": s.get("total"),
        } for s in storages if "backup" in (s.get("content") or "") and s.get("active")]

    async def next_id(self) -> int:
        return int(await self.get("/cluster/nextid"))

    async def tasks(self, node: str, limit: int = 30) -> list[dict]:
        data = await self.get(f"/nodes/{node}/tasks?limit={limit}") or []
        return [{
            "upid": t.get("upid"),
            "type": t.get("type"),
            "vmid": t.get("id"),
            "user": t.get("user"),
            "status": t.get("status") or ("running" if not t.get("endtime") else "OK"),
            "started": t.get("starttime"),
            "ended": t.get("endtime"),
        } for t in data]

    async def guest_rrd(self, node: str, kind: str, vmid: int,
                        timeframe: str = "hour") -> list[dict]:
        """Historique natif Proxmox : évite de dépendre de notre propre rétention."""
        data = await self.get(
            f"/nodes/{node}/{kind}/{vmid}/rrddata?timeframe={timeframe}&cf=AVERAGE"
        ) or []
        return [{
            "time": point.get("time"),
            "cpu": round(100.0 * (point.get("cpu") or 0), 2),
            "mem": point.get("mem"),
            "maxmem": point.get("maxmem"),
            "netin": point.get("netin"),
            "netout": point.get("netout"),
            "diskread": point.get("diskread"),
            "diskwrite": point.get("diskwrite"),
        } for point in data]

    def console_url(self, node: str, kind: str, vmid: int) -> str:
        """Lien vers la console noVNC de l'interface Proxmox native."""
        base = self.base.replace("/api2/json", "")
        console = "kvm" if kind == "qemu" else "lxc"
        return f"{base}/?console={console}&novnc=1&vmid={vmid}&node={node}&resize=off"


async def client_for_host(host: dict) -> ProxmoxClient:
    cred_id = host.get("credential_id")
    token = username = password = None
    if cred_id:
        cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
        if cred:
            secret = decrypt(cred["secret_enc"]) or ""
            if cred["kind"] in ("api_token", "token"):
                # Formes acceptées : « user@realm!id=uuid » complet dans le secret,
                # ou identifiant dans le champ utilisateur et uuid dans le secret.
                if "!" in secret and "=" in secret:
                    token = secret
                elif cred["username"] and "!" in cred["username"]:
                    token = f"{cred['username']}={secret}"
                else:
                    raise ProxmoxError(
                        "Format de jeton Proxmox invalide.\n\n"
                        "Attendu dans le champ Utilisateur : « root@pam!mba » "
                        "(utilisateur, point d'exclamation, identifiant du jeton), "
                        "et le UUID dans le champ Secret.\n"
                        f"Reçu : utilisateur « {cred['username'] or '(vide)'} ».\n\n"
                        + TOKEN_HELP
                    )
            else:
                username, password = cred["username"], secret
    return ProxmoxClient(host["address"], host.get("port") or 8006, token, username, password)
