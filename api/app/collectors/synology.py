"""Client Synology DSM (WebAPI)."""
from __future__ import annotations

import json
import logging
import re
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
    async def packages(self) -> dict[str, Any]:
        """Paquets installés, leur état et les mises à jour disponibles.

        DSM répond 120 (« paramètre invalide ») dès qu'un champ `additional`
        inconnu est demandé — `version` et `description` en font partie, alors
        même que ces valeurs figurent dans la réponse. Seuls `status`,
        `install_type`, `startable` et `dsm_apps` sont acceptés. On négocie donc
        la version déclarée par SYNO.API.Info, puis on dégrade les paramètres
        jusqu'à obtenir une réponse.
        """
        apis = await self.available_apis()
        version = self._api_version(apis, "SYNO.Core.Package", 2)
        if version is None:
            return {
                "packages": [], "updates": [],
                "reason": "L'API des paquets n'est pas exposée par ce DSM.",
            }

        # De la requête la plus riche à la plus dépouillée.
        attempts: list[tuple[int, dict]] = []
        for candidate in (version, 2, 1):
            attempts.append((candidate, {"additional": ["status", "install_type", "startable"]}))
            attempts.append((candidate, {"additional": ["status"]}))
            attempts.append((candidate, {}))

        data, errors, used = None, [], None
        seen = set()
        for candidate, params in attempts:
            # La clé porte aussi les valeurs : deux requêtes qui ne diffèrent que
            # par le contenu d'`additional` restent deux essais distincts.
            key = (candidate, json.dumps(params, sort_keys=True))
            if key in seen:
                continue
            seen.add(key)
            try:
                data = await self.call("SYNO.Core.Package", "list", candidate, **params)
                if data:
                    used = f"v{candidate} {'+'.join(params) or 'sans parametre'}"
                    break
            except SynologyError as exc:
                errors.append(str(exc))
                continue

        if not data:
            return {
                "packages": [], "updates": [],
                "reason": "DSM a refuse la lecture des paquets. Le compte utilise doit etre "
                          "administrateur. " + (errors[0] if errors else ""),
            }

        packages = []
        for pkg in (data.get("packages") or []):
            extra = pkg.get("additional") or {}
            packages.append({
                "id": pkg.get("id"),
                "name": pkg.get("name") or pkg.get("dname") or pkg.get("id"),
                "version": extra.get("version") or pkg.get("version"),
                "status": extra.get("status") or pkg.get("status"),
                "description": pkg.get("description") or extra.get("status_description"),
                "startable": extra.get("startable", True),
                "removable": pkg.get("removable", True),
            })
        packages.sort(key=lambda p: (p["status"] != "running", (p["name"] or "").lower()))

        return {"packages": packages, "updates": await self._package_updates(apis, packages),
                "api": used, "reason": None}

    @staticmethod
    def _version_key(version: str | None) -> tuple[int, ...]:
        """« 1.102.2-700102002 » → (1, 102, 2, 700102002), comparable numériquement.

        Une comparaison de chaînes classerait 1.102 avant 1.58, et ferait passer
        un paquet à jour pour une régression.
        """
        return tuple(int(part) for part in re.findall(r"\d+", version or "")) or (0,)

    async def _package_updates(self, apis: dict, installed: list[dict]) -> list[dict]:
        """Paquets dont le catalogue Synology propose une version plus récente.

        Le catalogue ne porte aucun indicateur de mise à jour : il liste ce que
        Synology publie, à charge pour nous de comparer avec ce qui tourne. Un
        paquet installé à la main peut d'ailleurs devancer le catalogue — on ne
        propose donc jamais de « mise à jour » vers une version antérieure.
        """
        version = self._api_version(apis, "SYNO.Core.Package.Server", 2)
        if version is None:
            return []
        current = {p["id"]: p for p in installed if p.get("id")}
        for params in ({"blforcereload": False, "blloadothers": False}, {}):
            try:
                data = await self.call("SYNO.Core.Package.Server", "list", version, **params)
            except SynologyError:
                continue
            catalog = (data or {}).get("packages") or []
            if not catalog:
                continue
            out = []
            for pkg in catalog:
                local = current.get(pkg.get("id"))
                if not local or pkg.get("beta"):
                    continue
                if self._version_key(pkg.get("version")) <= self._version_key(local.get("version")):
                    continue
                out.append({
                    "id": pkg.get("id"),
                    "name": pkg.get("dname") or pkg.get("id"),
                    "version": pkg.get("version"),
                    "installed_version": local.get("version"),
                    "security": bool(pkg.get("is_security_version")),
                    "changelog": pkg.get("changelog"),
                })
            out.sort(key=lambda p: p["name"].lower())
            return out
        return []

    async def package_action(self, package_id: str, action: str) -> Any:
        if action not in ("start", "stop"):
            raise SynologyError(f"Action paquet inconnue: {action}")
        return await self.call("SYNO.Core.Package.Control", action, 1, id=package_id)

    async def upgrade_package(self, package_id: str) -> dict[str, Any]:
        """Declenche la mise a jour d'un paquet depuis le catalogue Synology."""
        apis = await self.available_apis()
        version = self._api_version(apis, "SYNO.Core.Package.Installation", 1)
        if version is None:
            raise SynologyError(
                "L'API d'installation des paquets n'est pas exposee par ce DSM. "
                "Passe par le Centre de paquets."
            )
        data = await self.call("SYNO.Core.Package.Installation", "upgrade", version,
                               packages=[package_id], type=0)
        return {"task": data, "package": package_id}

    async def _first_success(self, api: str, method: str, version: int,
                             attempts: list[dict]) -> Any:
        """Premier jeu de paramètres accepté par DSM.

        Les méthodes d'écriture de DSM n'ont pas de contrat public stable : le
        nom du paramètre d'identifiant change d'une version à l'autre. On essaie
        les orthographes connues, et on remonte l'erreur DSM si aucune ne passe.
        """
        last: SynologyError | None = None
        for params in attempts:
            try:
                return await self.call(api, method, version, **params)
            except SynologyError as exc:
                last = exc
        raise last or SynologyError(f"{api}.{method} a échoué")

    # -------------------------------------------------------- mise à jour DSM
    async def dsm_update(self) -> dict[str, Any]:
        """Mise à jour du système : version proposée, téléchargement, réglages.

        Les trois API concernées (catalogue, téléchargement, installation) ne
        sont pas toujours exposées ensemble. Chacune est optionnelle : son
        absence se traduit par un champ vide, pas par une erreur.
        """
        apis = await self.available_apis()
        state: dict[str, Any] = {
            "current": None, "available": False, "version": None, "reboot": None,
            "type": None, "download": None, "auto_update": None,
            "can_download": False, "can_install": False, "reason": None,
        }

        try:
            info = await self.call("SYNO.Core.System", "info", 1) or {}
            state["current"] = info.get("firmware_ver")
        except SynologyError:
            pass

        version = self._api_version(apis, "SYNO.Core.Upgrade.Server", 1)
        if version is None:
            state["reason"] = ("L'API de mise à jour DSM n'est pas exposée par ce NAS. "
                               "Passe par le Panneau de configuration.")
            return state
        try:
            data = await self.call("SYNO.Core.Upgrade.Server", "check", version) or {}
        except SynologyError as exc:
            state["reason"] = (f"DSM a refusé la vérification ({exc}). Le compte utilisé "
                               "doit être administrateur.")
            return state

        update = data.get("update") or {}
        state.update({
            "available": bool(update.get("available")),
            # Selon les modèles, la version se lit dans `version` ou `dsm_version`.
            "version": update.get("version") or update.get("dsm_version"),
            "reboot": update.get("reboot"),
            "type": update.get("type"),
        })

        download_version = self._api_version(apis, "SYNO.Core.Upgrade.Server.Download", 1)
        state["can_download"] = download_version is not None
        if download_version is not None:
            try:
                progress = await self.call(
                    "SYNO.Core.Upgrade.Server.Download", "progress", download_version) or {}
                state["download"] = {
                    "status": progress.get("status"),
                    "percent": progress.get("progress"),
                    "finished": bool(progress.get("finished")),
                }
            except SynologyError:
                state["download"] = None

        state["can_install"] = self._api_version(apis, "SYNO.Core.Upgrade", 1) is not None

        setting_version = self._api_version(apis, "SYNO.Core.Upgrade.Setting", 1)
        if setting_version is not None:
            try:
                setting = await self.call("SYNO.Core.Upgrade.Setting", "get", setting_version) or {}
                state["auto_update"] = setting.get("autoupdateenable", setting.get("autoupdate"))
            except SynologyError:
                pass
        return state

    async def dsm_download(self) -> dict[str, Any]:
        """Télécharge la mise à jour DSM sans l'installer (aucune interruption)."""
        version = self._api_version(await self.available_apis(),
                                    "SYNO.Core.Upgrade.Server.Download", 1)
        if version is None:
            raise SynologyError("Ce NAS n'expose pas le téléchargement des mises à jour DSM.")
        return await self.call("SYNO.Core.Upgrade.Server.Download", "start", version) or {}

    async def dsm_install(self) -> dict[str, Any]:
        """Installe la mise à jour déjà téléchargée. Le NAS redémarre."""
        version = self._api_version(await self.available_apis(), "SYNO.Core.Upgrade", 1)
        if version is None:
            raise SynologyError("Ce NAS n'expose pas l'installation des mises à jour DSM.")
        return await self._first_success(
            "SYNO.Core.Upgrade", "start", version, [{"type": "nano"}, {}]) or {}

    # ---------------------------------------------------- tâches planifiées
    async def scheduled_tasks(self) -> dict[str, Any]:
        """Planificateur de tâches DSM (scripts, Hyper Backup, S.M.A.R.T., …)."""
        apis = await self.available_apis()
        version = self._api_version(apis, "SYNO.Core.TaskScheduler", 3)
        if version is None:
            return {"tasks": [], "reason": "Le planificateur DSM n'est pas exposé par ce NAS."}

        data = None
        errors: list[str] = []
        for params in ({"additional": ["next_trigger_time"], "offset": 0, "limit": 200}, {}):
            try:
                data = await self.call("SYNO.Core.TaskScheduler", "list", version, **params)
                if data:
                    break
            except SynologyError as exc:
                errors.append(str(exc))
        if not data:
            return {"tasks": [],
                    "reason": "DSM a refusé la lecture des tâches planifiées : le compte utilisé "
                              "doit être administrateur. " + (errors[0] if errors else "")}

        tasks = []
        for task in (data.get("tasks") or data.get("task") or []):
            extra = task.get("additional") or {}
            tasks.append({
                "id": task.get("id"),
                "name": task.get("name"),
                "owner": task.get("real_owner") or task.get("owner"),
                "type": task.get("type"),
                "enabled": bool(task.get("enable")),
                "schedule": task.get("schedule_desc") or task.get("desc"),
                "next_run": extra.get("next_trigger_time") or task.get("next_trigger_time"),
                "last_run": task.get("last_run_time"),
                "last_status": task.get("action_result") or task.get("status"),
                "can_run": task.get("can_run", True),
                "can_edit": task.get("can_edit", True),
            })
        tasks.sort(key=lambda t: (not t["enabled"], (t["name"] or "").lower()))
        return {"tasks": tasks, "reason": None}

    async def run_task(self, task_id: int) -> Any:
        version = self._api_version(await self.available_apis(), "SYNO.Core.TaskScheduler", 3)
        if version is None:
            raise SynologyError("Le planificateur DSM n'est pas exposé par ce NAS.")
        return await self._first_success(
            "SYNO.Core.TaskScheduler", "run", version,
            [{"task_id": task_id}, {"taskId": task_id}, {"id": task_id}],
        )

    async def set_task_enabled(self, task_id: int, enabled: bool) -> Any:
        version = self._api_version(await self.available_apis(), "SYNO.Core.TaskScheduler", 3)
        if version is None:
            raise SynologyError("Le planificateur DSM n'est pas exposé par ce NAS.")
        return await self._first_success(
            "SYNO.Core.TaskScheduler", "set_enable", version,
            [
                {"status": [{"id": task_id, "enable": enabled}]},
                {"task_id": task_id, "enable": enabled},
                {"id": task_id, "enable": enabled},
            ],
        )

    # ---------------------------------------------- services, comptes, accès
    async def services(self) -> dict[str, Any]:
        """Services DSM (SMB, NFS, SSH, …) et leur état d'activation."""
        version = self._api_version(await self.available_apis(), "SYNO.Core.Service", 1)
        if version is None:
            return {"services": [], "reason": "Ce NAS n'expose pas la liste des services."}
        try:
            data = await self.call("SYNO.Core.Service", "list", version,
                                   offset=0, limit=200) or {}
        except SynologyError as exc:
            return {"services": [], "reason": f"DSM a refusé la lecture des services : {exc}"}
        services = [{
            "id": item.get("id") or item.get("service"),
            "name": item.get("display_name") or item.get("description") or item.get("id"),
            "enabled": bool(item.get("enable_status", item.get("enable"))),
            "status": item.get("status"),
            "packagename": item.get("packagename"),
        } for item in (data.get("services") or [])]
        services.sort(key=lambda s: (not s["enabled"], (s["name"] or "").lower()))
        return {"services": services, "reason": None}

    async def users(self) -> dict[str, Any]:
        version = self._api_version(await self.available_apis(), "SYNO.Core.User", 1)
        if version is None:
            return {"users": [], "reason": "Ce NAS n'expose pas la liste des comptes."}
        try:
            data = await self.call("SYNO.Core.User", "list", version, offset=0, limit=200,
                                   additional=["description", "email", "expired"]) or {}
        except SynologyError as exc:
            return {"users": [], "reason": f"DSM a refusé la lecture des comptes : {exc}"}
        return {
            "users": [{
                "name": user.get("name"),
                "description": user.get("description"),
                "email": user.get("email"),
                "expired": user.get("expired"),
                "admin": bool(user.get("is_admin") or user.get("name") == "admin"),
            } for user in (data.get("users") or [])],
            "reason": None,
        }

    async def connections(self) -> dict[str, Any]:
        """Sessions actuellement ouvertes sur le NAS (SMB, DSM, SSH, …)."""
        version = self._api_version(await self.available_apis(), "SYNO.Core.CurrentConnection", 1)
        if version is None:
            return {"connections": [], "reason": "Ce NAS n'expose pas les connexions en cours."}
        try:
            data = await self.call("SYNO.Core.CurrentConnection", "list", version,
                                   offset=0, limit=200) or {}
        except SynologyError as exc:
            return {"connections": [], "reason": f"DSM a refusé la lecture des connexions : {exc}"}
        return {
            "connections": [{
                "who": item.get("who"),
                "from": item.get("from"),
                "type": item.get("type"),
                "descr": item.get("descr"),
                "time": item.get("time"),
            } for item in (data.get("items") or data.get("connections") or [])],
            "reason": None,
        }

    async def shares(self) -> list[dict]:
        data = await self.call("SYNO.Core.Share", "list", 1, additional=["size", "volume_status"])
        return data.get("shares") or []

    async def _backup_repositories(self, apis: dict) -> dict[Any, dict]:
        """Destinations Hyper Backup, indexées par `repo_id`.

        La tâche ne connaît que l'identifiant de son dépôt : sans cet appel, on
        ne sait pas dire *où* elle sauvegarde, ni si c'est hors site.
        """
        version = self._api_version(apis, "SYNO.Backup.Repository", 1)
        if version is None:
            return {}
        try:
            data = await self.call("SYNO.Backup.Repository", "list", version) or {}
        except SynologyError:
            return {}
        # On ne recopie que ce qui décrit la destination : la réponse contient
        # aussi le compte et le mot de passe du dépôt.
        return {
            repo.get("repo_id"): {
                "name": repo.get("name"),
                "dest": repo.get("dest"),
                "share": repo.get("share"),
                "target_type": repo.get("target_type"),
                "transfer_type": repo.get("transfer_type"),
            }
            for repo in (data.get("repo_list") or [])
        }

    async def _backup_history(self, apis: dict, task_id: Any) -> dict[str, Any]:
        """Dernière sauvegarde réussie, dernière tentative, nombre de versions.

        La liste des tâches ne porte aucun horodatage — DSM range l'historique
        dans une API séparée. Sans elle, une tâche parfaitement saine remonte
        avec « date de dernière sauvegarde inconnue ».
        """
        empty: dict[str, Any] = {"last_backup": None, "last_attempt": None,
                                 "last_result": None, "versions": 0}
        version = self._api_version(apis, "SYNO.Backup.Version", 2)
        if task_id is None or version is None:
            return empty
        try:
            data = await self.call("SYNO.Backup.Version", "list", version, task_id=task_id) or {}
        except SynologyError:
            return empty

        entries = data.get("version_info_list") or []
        total = int(data.get("total") or len(entries))
        if not entries:
            return {**empty, "versions": total}

        recent = sorted(entries, key=lambda v: v.get("timestamp") or 0, reverse=True)
        last = recent[0]
        success = next((v for v in recent if str(v.get("status", "")).lower() == "success"), None)
        # `complete_time` vaut 0 quand la session a échoué : on retombe alors sur
        # l'heure de départ, seule valeur exploitable.
        return {
            "last_backup": (success or {}).get("complete_time") or (success or {}).get("timestamp"),
            "last_attempt": last.get("complete_time") or last.get("timestamp"),
            "last_result": last.get("status"),
            "versions": total,
        }

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
            # Un NAS qui *reçoit* des sauvegardes n'expose que les API « Server » :
            # il n'a aucune tâche à lister, et ce n'est pas une anomalie.
            vault = any(name.startswith("SYNO.SDS.Backup.Server.") for name in apis)
            return {
                "installed": False,
                "role": "destination" if vault else None,
                "tasks": [],
                "reason": "Ce NAS est une destination Hyper Backup (Vault) : il reçoit les "
                          "sauvegardes d'autres machines et n'exécute pas de tâche lui-même."
                if vault else
                "Hyper Backup n'est pas installé sur ce NAS, ou son API n'est pas "
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
        repositories = await self._backup_repositories(apis)
        tasks = []
        for task in raw:
            task_id = task.get("task_id") or task.get("id")
            history = await self._backup_history(apis, task_id)
            repo = repositories.get(task.get("repo_id")) or {}

            state = (task.get("status") or task.get("state") or "").lower()
            transfer = str(task.get("transfer_type") or repo.get("transfer_type") or "").lower()
            target_type = str(task.get("type") or task.get("target_type")
                              or repo.get("target_type") or "").lower()
            target = task.get("target") or task.get("repo_dir") or task.get("dest") or ""
            if not target and repo:
                target = ":".join(p for p in (repo.get("dest"), repo.get("share")) if p) \
                    or (repo.get("name") or "")
            # Une destination C2 se reconnaît au type ou au nom du dépôt.
            is_c2 = "c2" in target_type or "c2" in transfer or "c2" in str(target).lower()

            tasks.append({
                "id": task_id,
                "name": task.get("name") or task.get("task_name"),
                "target": target,
                "type": target_type or transfer,
                "is_c2": is_c2,
                # Un dépôt distant vaut copie hors site, C2 ou pas.
                "offsite": is_c2 or "remote" in transfer,
                "state": state,
                "last_backup": history["last_backup"]
                or task.get("last_bkp_end_time") or task.get("last_backup_time"),
                "last_attempt": history["last_attempt"],
                "last_result": history["last_result"]
                or task.get("last_bkp_result") or task.get("last_result"),
                "next_backup": task.get("next_bkp_time"),
                "versions": history["versions"],
                "size": task.get("data_size") or task.get("used_size"),
                "transfer_size": task.get("transfer_size"),
                "schedule": task.get("schedule_desc") or task.get("sched_desc"),
                "enabled": task.get("sched_enable", task.get("enable", True)),
            })
        return {"installed": True, "role": "source", "tasks": tasks, "api": used, "reason": None}

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
