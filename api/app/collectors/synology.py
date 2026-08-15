"""Client Synology DSM (WebAPI)."""
from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from ..db import fetch_one
from ..vault import decrypt

log = logging.getLogger("mba.syno")

ERRORS = {
    400: "Identifiants invalides",
    401: "Compte désactivé",
    402: "Permission refusée",
    403: "Double authentification requise (renseigne un code OTP)",
    404: "Code OTP invalide",
    407: "Adresse IP bloquée par DSM",
}


class SynologyError(RuntimeError):
    pass


class SynologyClient:
    def __init__(self, address: str, port: int = 5001, username: str = "",
                 password: str = "", secure: bool = True, otp: str | None = None) -> None:
        scheme = "https" if secure else "http"
        self.base = f"{scheme}://{address}:{port}/webapi"
        self.username = username
        self.password = password
        self.otp = otp
        self._sid: str | None = None
        self._apis: dict[str, dict] | None = None
        self._client = httpx.AsyncClient(verify=False, timeout=20.0, follow_redirects=True)

    # -------------------------------------------------------------------- auth
    async def login(self) -> str:
        params = {
            "api": "SYNO.API.Auth", "version": "6", "method": "login",
            "account": self.username, "passwd": self.password,
            "session": "MyBeautifulAdmin", "format": "sid",
        }
        if self.otp:
            params["otp_code"] = self.otp
        resp = await self._client.get(f"{self.base}/auth.cgi", params=params)
        payload = resp.json()
        if not payload.get("success"):
            code = (payload.get("error") or {}).get("code", 0)
            raise SynologyError(ERRORS.get(code, f"Échec de connexion DSM (code {code})"))
        self._sid = payload["data"]["sid"]
        return self._sid

    async def logout(self) -> None:
        if self._sid:
            try:
                await self._client.get(f"{self.base}/auth.cgi", params={
                    "api": "SYNO.API.Auth", "version": "6", "method": "logout",
                    "session": "MyBeautifulAdmin", "_sid": self._sid})
            except httpx.HTTPError:
                pass
            self._sid = None
        await self._client.aclose()

    # ------------------------------------------------------------------ appels
    async def call(self, api: str, method: str, version: int = 1, cgi: str = "entry.cgi",
                   **extra: Any) -> Any:
        if not self._sid:
            await self.login()
        params: dict[str, Any] = {"api": api, "version": str(version), "method": method, "_sid": self._sid}
        for key, value in extra.items():
            params[key] = json.dumps(value) if isinstance(value, (list, dict)) else value
        resp = await self._client.get(f"{self.base}/{cgi}", params=params)
        try:
            payload = resp.json()
        except ValueError as exc:
            raise SynologyError(f"Réponse DSM illisible ({resp.status_code})") from exc
        if not payload.get("success"):
            code = (payload.get("error") or {}).get("code", 0)
            if code in (105, 106, 107, 119):  # session expirée
                self._sid = None
                await self.login()
                return await self.call(api, method, version, cgi, **extra)
            raise SynologyError(f"{api}.{method} → erreur DSM {code}")
        return payload.get("data")

    async def available_apis(self) -> dict[str, dict]:
        """Catalogue des API exposées par ce DSM, avec leurs versions.

        DSM ne publie une API que si le paquet correspondant est installé :
        c'est la façon fiable de savoir si Hyper Backup est présent.
        """
        if self._apis is not None:
            return self._apis
        try:
            data = await self.call("SYNO.API.Info", "query", 1, cgi="query.cgi", query="all")
            self._apis = data or {}
        except SynologyError:
            self._apis = {}
        return self._apis

    def _api_version(self, apis: dict, name: str, wanted: int) -> int | None:
        entry = apis.get(name)
        if not entry:
            return None
        low = int(entry.get("minVersion", 1))
        high = int(entry.get("maxVersion", 1))
        return max(low, min(wanted, high))

    # -------------------------------------------------------------- collecteur
    async def snapshot(self) -> dict[str, Any]:
        util = await self.call("SYNO.Core.System.Utilization", "get", 1)
        try:
            info = await self.call("SYNO.Core.System", "info", 1)
        except SynologyError:
            info = {}
        try:
            storage = await self.call("SYNO.Storage.CGI.Storage", "load_info", 1)
        except SynologyError:
            storage = {}

        cpu = util.get("cpu", {})
        cpu_usage = sum(float(cpu.get(k, 0) or 0) for k in ("user_load", "system_load", "other_load"))
        mem = util.get("memory", {})
        mem_total = float(mem.get("memory_size", 0) or 0) * 1024  # DSM renvoie des Ko
        mem_used = float(mem.get("real_usage", 0) or 0) / 100.0 * mem_total

        net = util.get("network", [])
        net_total = next((n for n in net if n.get("device") == "total"), net[0] if net else {})
        disk = util.get("disk", {})
        disk_total = disk.get("total", {})

        metrics = {
            "cpu.usage": round(cpu_usage, 2),
            "load.1": float(cpu.get("1min_load", 0) or 0) / 100.0,
            "load.5": float(cpu.get("5min_load", 0) or 0) / 100.0,
            "load.15": float(cpu.get("15min_load", 0) or 0) / 100.0,
            "mem.percent": float(mem.get("real_usage", 0) or 0),
            "mem.total": mem_total,
            "mem.used": mem_used,
            "net.rx": float(net_total.get("rx", 0) or 0),
            "net.tx": float(net_total.get("tx", 0) or 0),
            "disk.read": float(disk_total.get("read_byte", 0) or 0),
            "disk.write": float(disk_total.get("write_byte", 0) or 0),
            "uptime": float(info.get("up_time", "0").split(":")[0] or 0) * 3600
            if isinstance(info.get("up_time"), str) else float(info.get("up_time", 0) or 0),
        }

        volumes = []
        for vol in (storage.get("volumes") or []):
            total = float(vol.get("size", {}).get("total", 0) or 0)
            used = float(vol.get("size", {}).get("used", 0) or 0)
            volumes.append({
                "id": vol.get("id"),
                "name": vol.get("id", "").replace("volume_", "Volume "),
                "fs": vol.get("fs_type"),
                "status": vol.get("status"),
                "total": total,
                "used": used,
                "percent": round(100.0 * used / total, 2) if total else 0.0,
                "raid": vol.get("raid_type") or vol.get("container"),
            })
            if total:
                metrics[f"syno.volume.{vol.get('id')}"] = round(100.0 * used / total, 2)

        if volumes:
            metrics["disk.percent"] = max(v["percent"] for v in volumes)
            metrics["disk.total"] = sum(v["total"] for v in volumes)
            metrics["disk.used"] = sum(v["used"] for v in volumes)

        disks = [{
            "id": d.get("id"),
            "name": d.get("name") or d.get("id"),
            "model": (d.get("model") or "").strip(),
            "vendor": (d.get("vendor") or "").strip(),
            "size": float(d.get("size_total", 0) or 0),
            "temp": d.get("temp"),
            "status": d.get("status"),
            "smart": d.get("smart_status") or d.get("smart_test_status"),
            "type": d.get("diskType"),
        } for d in (storage.get("disks") or [])]

        temps = [d["temp"] for d in disks if isinstance(d.get("temp"), (int, float)) and d["temp"] > 0]
        if temps:
            metrics["temp.disks_max"] = max(temps)
        if isinstance(info.get("sys_temp"), (int, float)):
            metrics["temp.cpu"] = float(info["sys_temp"])

        return {
            "metrics": metrics,
            "info": {
                "model": info.get("model"),
                "serial": info.get("serial"),
                "dsm_version": info.get("firmware_ver"),
                "temperature": info.get("sys_temp"),
                "temp_warn": bool(info.get("temperature_warning")),
                "ntp": info.get("ntp_server"),
                "time": info.get("time"),
            },
            "volumes": volumes,
            "disks": disks,
            "pools": [{
                "id": p.get("id"),
                "raid": p.get("raid_type") or p.get("container"),
                "status": p.get("status"),
                "size": float((p.get("size") or {}).get("total", 0) or 0),
            } for p in (storage.get("storagePools") or [])],
        }

    # ---------------------------------------------------------------- services
    async def packages(self) -> list[dict]:
        data = await self.call("SYNO.Core.Package", "list", 2, additional=["status", "version"])
        return [{
            "id": p.get("id"),
            "name": p.get("name") or p.get("id"),
            "version": p.get("version"),
            "status": p.get("additional", {}).get("status") or p.get("status"),
        } for p in (data.get("packages") or [])]

    async def package_action(self, package_id: str, action: str) -> Any:
        if action not in ("start", "stop"):
            raise SynologyError(f"Action paquet inconnue: {action}")
        return await self.call("SYNO.Core.Package.Control", action, 1, id=package_id)

    async def shares(self) -> list[dict]:
        data = await self.call("SYNO.Core.Share", "list", 1, additional=["size", "volume_status"])
        return data.get("shares") or []

    async def hyper_backup(self) -> dict[str, Any]:
        """Tâches Hyper Backup, avec le motif d'absence quand il n'y en a pas."""
        apis = await self.available_apis()
        candidates = [
            ("SYNO.Backup.Task", 1),
            ("SYNO.Backup.Task", 2),
            ("SYNO.SDS.Backup.Client.Common.Task", 1),
        ]
        available = [(name, self._api_version(apis, name, wanted))
                     for name, wanted in candidates]
        available = [(name, version) for name, version in available if version]

        if not available:
            return {
                "installed": False,
                "tasks": [],
                "reason": "Hyper Backup n'est pas installé sur ce NAS, ou son API n'est pas "
                          "exposée (le paquet doit être démarré).",
            }

        data, used = None, None
        errors = []
        for name, version in available:
            try:
                data = await self.call(name, "list", version)
                if data:
                    used = f"{name} v{version}"
                    break
            except SynologyError as exc:
                errors.append(str(exc))
                continue

        if not data:
            return {
                "installed": True,
                "tasks": [],
                "reason": "Hyper Backup est présent mais son API refuse la lecture : "
                          "le compte DSM utilisé doit être administrateur. "
                          + (errors[0] if errors else ""),
            }

        raw = data.get("task_list") or data.get("tasks") or []
        tasks = []
        for task in raw:
            state = (task.get("status") or task.get("state") or "").lower()
            target = task.get("target") or task.get("repo_dir") or task.get("dest") or ""
            target_type = (task.get("type") or task.get("target_type") or "").lower()
            tasks.append({
                "id": task.get("task_id") or task.get("id"),
                "name": task.get("name") or task.get("task_name"),
                "target": target,
                "type": target_type,
                # Une destination C2 se reconnaît au type ou au nom du dépôt.
                "is_c2": "c2" in target_type or "c2" in str(target).lower(),
                "state": state,
                "last_backup": task.get("last_bkp_end_time") or task.get("last_backup_time"),
                "last_result": task.get("last_bkp_result") or task.get("last_result"),
                "next_backup": task.get("next_bkp_time"),
                "size": task.get("data_size") or task.get("used_size"),
                "transfer_size": task.get("transfer_size"),
                "schedule": task.get("schedule_desc") or task.get("sched_desc"),
                "enabled": task.get("sched_enable", task.get("enable", True)),
            })
        return {"installed": True, "tasks": tasks, "api": used, "reason": None}

    async def snapshot_tasks(self) -> list[dict]:
        """Snapshot Replication : deuxième filet de sécurité sur les volumes."""
        try:
            data = await self.call("SYNO.Core.Share.Snapshot", "list_all", 1)
        except SynologyError:
            return []
        return [{
            "share": item.get("share_name"),
            "time": item.get("time"),
            "description": item.get("desc"),
            "locked": bool(item.get("lock")),
        } for item in (data.get("snapshots") or [])]

    async def check_updates(self) -> dict:
        try:
            return await self.call("SYNO.Core.Upgrade.Server", "check", 1) or {}
        except SynologyError:
            return {}

    async def system_action(self, action: str) -> Any:
        if action not in ("reboot", "shutdown"):
            raise SynologyError(f"Action système inconnue: {action}")
        return await self.call("SYNO.Core.System", action, 1)


async def client_for_host(host: dict) -> SynologyClient:
    cred_id = host.get("credential_id")
    if not cred_id:
        raise SynologyError(f"Aucun credential DSM pour « {host['name']} »")
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
    if not cred:
        raise SynologyError("Credential introuvable")
    meta = host.get("meta") or {}
    port = host.get("port") or 5001
    return SynologyClient(
        address=host["address"],
        port=port,
        username=cred["username"] or "",
        password=decrypt(cred["secret_enc"]) or "",
        secure=meta.get("secure", port != 5000),
        otp=decrypt(cred["passphrase_enc"]),
    )
