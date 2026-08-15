"""Contrôleurs de gestion hors-bande (BMC) : ASUS ASMB, Supermicro, iDRAC, iLO…

Deux transports, choisis par hôte :

* **Redfish** (HTTPS) — standard DMTF, présent sur les ASMB9/ASMB10 récents.
  Tout passe en HTTP, rien à installer côté MBA.
* **ipmitool** — exécuté en SSH depuis une machine du réseau, pour les BMC plus
  anciens ou quand Redfish est désactivé.

Dans les deux cas on expose la même forme de données : état d'alimentation,
capteurs thermiques, ventilateurs, consommation, journal d'évènements (SEL).
"""
from __future__ import annotations

import contextlib
import logging
import re
from typing import Any

import httpx

from ..db import fetch_one
from ..ssh import SSHError, pool
from ..vault import decrypt

log = logging.getLogger("mba.ipmi")

# Actions Redfish ↔ verbes ipmitool.
POWER_ACTIONS = {
    "on": ("On", "on"),
    "off": ("ForceOff", "off"),
    "graceful": ("GracefulShutdown", "soft"),
    "restart": ("ForceRestart", "reset"),
    "cycle": ("PowerCycle", "cycle"),
    "nmi": ("Nmi", "diag"),
}


class IPMIError(RuntimeError):
    pass


# ============================================================ Redfish (HTTPS)
class RedfishClient:
    def __init__(self, address: str, username: str, password: str, port: int = 443,
                 secure: bool = True) -> None:
        scheme = "https" if secure else "http"
        self.base = f"{scheme}://{address}:{port}"
        self.auth = (username, password)
        self._system: str | None = None
        self._chassis: str | None = None
        self._manager: str | None = None

    def _client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            verify=False, timeout=25.0, auth=self.auth, base_url=self.base,
            follow_redirects=True,
            # Certains BMC ASUS renvoient du HTML si l'Accept n'est pas explicite.
            headers={"Accept": "application/json", "OData-Version": "4.0"},
        )

    async def _get(self, client: httpx.AsyncClient, path: str) -> dict:
        resp = await client.get(path)
        if resp.status_code == 401:
            raise IPMIError("Identifiants BMC refusés (401)")
        if resp.status_code == 404:
            return {}
        if resp.status_code >= 400:
            raise IPMIError(f"Redfish {path} → {resp.status_code}")
        try:
            return resp.json()
        except ValueError:
            return {}

    async def _resolve(self, client: httpx.AsyncClient) -> None:
        """Trouve les URIs Systems/Chassis/Managers — ils varient d'un BMC à l'autre."""
        if self._system:
            return
        root = None
        for candidate in ("/redfish/v1", "/redfish/v1/"):
            root = await self._get(client, candidate)
            if root:
                break
        if not root:
            raise IPMIError(
                "Redfish ne répond pas sur ce BMC. Sur un ASMB10-iKVM, vérifie que le service "
                "est activé (Settings → Services → redfish) ou bascule en mode ipmitool."
            )

        async def first(collection: str, fallbacks: tuple[str, ...]) -> str | None:
            uri = (root.get(collection) or {}).get("@odata.id")
            if uri:
                listing = await self._get(client, uri)
                members = (listing or {}).get("Members") or []
                if members:
                    return members[0].get("@odata.id")
            # Repli sur les identifiants usuels quand la collection est vide.
            for path in fallbacks:
                if await self._get(client, path):
                    return path
            return None

        self._system = await first("Systems", ("/redfish/v1/Systems/1", "/redfish/v1/Systems/Self"))
        self._chassis = await first("Chassis", ("/redfish/v1/Chassis/1", "/redfish/v1/Chassis/Self"))
        self._manager = await first("Managers", ("/redfish/v1/Managers/1", "/redfish/v1/Managers/Self"))
        if not self._system:
            raise IPMIError("Aucun système exposé par ce BMC")

    # ---------------------------------------------------------------- lecture
    async def snapshot(self) -> dict[str, Any]:
        async with self._client() as client:
            await self._resolve(client)
            system = await self._get(client, self._system)
            thermal = await self._get(client, f"{self._chassis}/Thermal") if self._chassis else {}
            power = await self._get(client, f"{self._chassis}/Power") if self._chassis else {}
            manager = await self._get(client, self._manager) if self._manager else {}

        temps, fans = {}, {}
        for sensor in thermal.get("Temperatures") or []:
            reading = sensor.get("ReadingCelsius")
            name = sensor.get("Name") or sensor.get("MemberId")
            if isinstance(reading, (int, float)) and 0 < reading < 150 and name:
                temps[name] = float(reading)
        for fan in thermal.get("Fans") or []:
            reading = fan.get("Reading") if fan.get("Reading") is not None else fan.get("ReadingRPM")
            name = fan.get("Name") or fan.get("MemberId")
            if isinstance(reading, (int, float)) and name:
                fans[name] = float(reading)

        watts, psus = None, []
        for control in power.get("PowerControl") or []:
            if isinstance(control.get("PowerConsumedWatts"), (int, float)):
                watts = float(control["PowerConsumedWatts"])
        for psu in power.get("PowerSupplies") or []:
            psus.append({
                "name": psu.get("Name"),
                "status": (psu.get("Status") or {}).get("Health"),
                "state": (psu.get("Status") or {}).get("State"),
                "model": psu.get("Model"),
                "capacity": psu.get("PowerCapacityWatts"),
                "input": psu.get("PowerInputWatts"),
            })

        memory = system.get("MemorySummary") or {}
        processors = system.get("ProcessorSummary") or {}

        # Le BMC déclare les ResetType qu'il accepte : on n'exposera que ceux-là.
        reset = ((system.get("Actions") or {}).get("#ComputerSystem.Reset") or {})
        allowed = reset.get("ResetType@Redfish.AllowableValues") or []
        supported = [key for key, (redfish, _) in POWER_ACTIONS.items()
                     if not allowed or redfish in allowed]

        chassis_info = {}
        if self._chassis:
            chassis_info = await self._chassis_info()

        return {
            "supported_actions": supported,
            "console_url": self.base,
            "power_state": (system.get("PowerState") or "Unknown").lower(),
            "health": (system.get("Status") or {}).get("Health"),
            "model": system.get("Model"),
            "manufacturer": system.get("Manufacturer"),
            "serial": system.get("SerialNumber"),
            "bios": system.get("BiosVersion"),
            "host_name": system.get("HostName"),
            "cpu_count": processors.get("Count"),
            "cpu_model": processors.get("Model"),
            "mem_total": (memory.get("TotalSystemMemoryGiB") or 0) * 1024**3 or None,
            "bmc_firmware": manager.get("FirmwareVersion"),
            "bmc_model": manager.get("Model"),
            "temps": temps,
            "fans": fans,
            "power_watts": watts,
            "psus": psus,
            **chassis_info,
        }

    async def _chassis_info(self) -> dict[str, Any]:
        """Complète l'identité quand le System ne porte pas le modèle (cas ASUS)."""
        async with self._client() as client:
            chassis = await self._get(client, self._chassis) or {}
        return {k: v for k, v in {
            "chassis_model": chassis.get("Model"),
            "chassis_manufacturer": chassis.get("Manufacturer"),
            "chassis_serial": chassis.get("SerialNumber"),
            "chassis_part": chassis.get("PartNumber"),
            "indicator_led": chassis.get("IndicatorLED"),
        }.items() if v}

    async def sel(self, limit: int = 60) -> list[dict]:
        async with self._client() as client:
            await self._resolve(client)
            services = await self._get(client, f"{self._system}/LogServices")
            entries: list[dict] = []
            for member in (services.get("Members") or [])[:2]:
                data = await self._get(client, f"{member['@odata.id']}/Entries")
                for item in (data.get("Members") or [])[-limit:]:
                    entries.append({
                        "time": item.get("Created"),
                        "severity": (item.get("Severity") or "OK").lower(),
                        "message": item.get("Message") or item.get("Name"),
                        "sensor": item.get("SensorType"),
                    })
        entries.sort(key=lambda e: e.get("time") or "", reverse=True)
        return entries[:limit]

    # ---------------------------------------------------------------- actions
    async def power(self, action: str) -> str:
        if action not in POWER_ACTIONS:
            raise IPMIError(f"Action d'alimentation inconnue : {action}")
        reset_type = POWER_ACTIONS[action][0]
        async with self._client() as client:
            await self._resolve(client)
            resp = await client.post(
                f"{self._system}/Actions/ComputerSystem.Reset",
                json={"ResetType": reset_type},
            )
        if resp.status_code >= 400:
            detail = resp.text[:180]
            if resp.status_code in (400, 405):
                detail += " — ce contrôleur n'accepte peut-être pas cette action ; "
                detail += "essaie « Arrêt propre » ou « Cycle d'alimentation »."
            raise IPMIError(f"Refus du BMC ({resp.status_code}) : {detail}")
        return reset_type

    async def identify(self, on: bool = True) -> None:
        """Allume la LED de localisation, pour retrouver la machine dans la baie."""
        value = "Lit" if on else "Off"
        async with self._client() as client:
            await self._resolve(client)
            resp = await client.patch(self._system, json={"IndicatorLED": value})
            # Sur l'ASMB, la LED est portée par le Chassis et non par le System.
            if resp.status_code >= 400 and self._chassis:
                resp = await client.patch(self._chassis, json={"IndicatorLED": value})
            if resp.status_code >= 400:
                raise IPMIError(f"LED non pilotable via Redfish ({resp.status_code})")


# ========================================================= ipmitool (via SSH)
class IpmitoolClient:
    """Pilote un BMC via `ipmitool` exécuté sur une machine relais en SSH."""

    def __init__(self, proxy_host: dict, address: str, username: str, password: str) -> None:
        self.proxy = proxy_host
        self.address = address
        self.username = username
        self.password = password

    def _cmd(self, args: str) -> str:
        # Le mot de passe passe par l'environnement : il n'apparaît pas dans ps.
        return (
            f"IPMI_PASSWORD={_shquote(self.password)} ipmitool -I lanplus "
            f"-H {_shquote(self.address)} -U {_shquote(self.username)} -E {args}"
        )

    async def _run(self, args: str, timeout: float = 25) -> str:
        try:
            code, out, err = await pool.run_status(self.proxy, self._cmd(args), timeout)
        except SSHError as exc:
            raise IPMIError(f"Relais {self.proxy['name']} injoignable : {exc}") from exc
        if code != 0:
            message = (err or out).strip()[:200]
            if "command not found" in message.lower():
                raise IPMIError(f"ipmitool n'est pas installé sur {self.proxy['name']}")
            raise IPMIError(message or f"ipmitool a échoué (code {code})")
        return out

    async def snapshot(self) -> dict[str, Any]:
        status = await self._run("chassis status")
        power_state = "on" if re.search(r"System Power\s*:\s*on", status, re.I) else "off"

        temps, fans, watts = {}, {}, None
        sensors = await self._run("sdr elist full")
        for line in sensors.splitlines():
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 5:
                continue
            name, reading = parts[0], parts[4]
            value = re.match(r"^([\d.]+)\s*(degrees C|RPM|Watts)", reading, re.I)
            if not value:
                continue
            number, unit = float(value.group(1)), value.group(2).lower()
            if unit.startswith("degrees") and 0 < number < 150:
                temps[name] = number
            elif unit == "rpm":
                fans[name] = number
            elif unit == "watts" and ("pwr" in name.lower() or "power" in name.lower()):
                watts = number

        return {
            "power_state": power_state,
            "health": None,
            "temps": temps,
            "fans": fans,
            "power_watts": watts,
            "psus": [],
        }

    async def sel(self, limit: int = 60) -> list[dict]:
        raw = await self._run(f"sel list last {int(limit)}")
        entries = []
        for line in raw.splitlines():
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 4:
                continue
            entries.append({
                "time": f"{parts[1]} {parts[2]}" if len(parts) > 2 else None,
                "severity": "critical" if "critical" in line.lower() else "ok",
                "message": " · ".join(parts[3:]),
                "sensor": parts[3] if len(parts) > 3 else None,
            })
        return list(reversed(entries))

    async def power(self, action: str) -> str:
        if action not in POWER_ACTIONS:
            raise IPMIError(f"Action d'alimentation inconnue : {action}")
        verb = POWER_ACTIONS[action][1]
        await self._run(f"chassis power {verb}", timeout=40)
        return verb

    async def identify(self, on: bool = True) -> None:
        await self._run(f"chassis identify {'force' if on else '0'}")


# ============================================================== diagnostic
async def diagnose(address: str, port: int, username: str, password: str,
                   secure: bool = True) -> dict[str, Any]:
    """Déroule la chaîne de connexion et dit précisément où elle casse.

    « Injoignable » ne suffit pas à dépanner un BMC : on distingue la
    résolution DNS, l'ouverture du port, la poignée de main TLS,
    l'authentification et la présence effective de Redfish.
    """
    import asyncio
    import socket
    import ssl

    steps: list[dict[str, Any]] = []

    def add(name: str, ok: bool, detail: str, hint: str = "") -> None:
        steps.append({"step": name, "ok": ok, "detail": detail, "hint": hint})

    # 1. Résolution du nom -------------------------------------------------
    resolved = address
    try:
        loop = asyncio.get_running_loop()
        infos = await asyncio.wait_for(
            loop.getaddrinfo(address, port, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM),
            timeout=6,
        )
        resolved = infos[0][4][0]
        add("dns", True, f"{address} → {resolved}")
    except (socket.gaierror, asyncio.TimeoutError, OSError) as exc:
        add("dns", False, f"Impossible de résoudre « {address} » ({exc})",
            "Le conteneur ne voit pas le mDNS (.local) ni le DNS de ta box. "
            "Utilise l'adresse IP du BMC, ou ajoute une entrée extra_hosts au compose.")
        return {"ok": False, "steps": steps}

    # 2. Ouverture du port -------------------------------------------------
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(resolved, port), timeout=6
        )
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        add("tcp", True, f"Port {port} ouvert")
    except (asyncio.TimeoutError, OSError) as exc:
        add("tcp", False, f"Port {port} injoignable ({type(exc).__name__})",
            "Vérifie que l'interface de gestion est bien sur ce réseau et que le port "
            "correspond (443 pour Redfish, 80 si HTTPS désactivé).")
        return {"ok": False, "steps": steps}

    # 3. Poignée de main TLS ----------------------------------------------
    if secure:
        try:
            context = ssl.create_default_context()
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(resolved, port, ssl=context), timeout=8
            )
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            add("tls", True, "Poignée de main TLS acceptée")
        except (ssl.SSLError, asyncio.TimeoutError, OSError) as exc:
            add("tls", False, f"TLS refusé ({exc})",
                "Ce BMC répond peut-être en HTTP simple : décoche « HTTPS ».")
            return {"ok": False, "steps": steps}

    # 4. Redfish présent ? -------------------------------------------------
    scheme = "https" if secure else "http"
    base = f"{scheme}://{address}:{port}"
    async with httpx.AsyncClient(verify=False, timeout=15.0, base_url=base,
                                 headers={"Accept": "application/json"},
                                 follow_redirects=True) as client:
        try:
            resp = await client.get("/redfish/v1")
            if resp.status_code == 404:
                resp = await client.get("/redfish/v1/")
        except httpx.HTTPError as exc:
            add("redfish", False, f"Pas de réponse HTTP ({exc})",
                "Bascule en mode ipmitool depuis une machine relais.")
            return {"ok": False, "steps": steps}

        if resp.status_code == 404:
            add("redfish", False, "Redfish absent (404 sur /redfish/v1)",
                "Sur un ASMB10-iKVM : interface web → Settings → Services, active « redfish ». "
                "Sinon, utilise le mode ipmitool.")
            return {"ok": False, "steps": steps}
        if resp.status_code >= 500:
            add("redfish", False, f"Le BMC répond {resp.status_code}",
                "Redémarre le contrôleur depuis son interface web (Maintenance → Unit Reset).")
            return {"ok": False, "steps": steps}
        add("redfish", True, "Service Redfish détecté")

        # 5. Authentification ----------------------------------------------
        auth_resp = await client.get("/redfish/v1/Systems", auth=(username, password))
        if auth_resp.status_code == 401:
            add("auth", False, "Identifiants refusés (401)",
                "Utilise le compte du BMC lui-même (souvent « admin »), pas celui du système. "
                "Certains ASMB exigent un mot de passe changé au premier accès.")
            return {"ok": False, "steps": steps}
        if auth_resp.status_code >= 400:
            add("auth", False, f"Accès refusé ({auth_resp.status_code})",
                "Le compte existe peut-être sans le rôle Administrator.")
            return {"ok": False, "steps": steps}
        add("auth", True, "Authentification acceptée")

    # 6. Lecture effective -------------------------------------------------
    client = RedfishClient(address, username, password, port, secure)
    try:
        snap = await client.snapshot()
    except IPMIError as exc:
        add("inventaire", False, str(exc), "Le BMC répond mais son modèle de données diffère.")
        return {"ok": False, "steps": steps}

    add("inventaire", True,
        f"{snap.get('model') or 'système'} · alimentation {snap.get('power_state')} · "
        f"{len(snap.get('temps') or {})} capteur(s), {len(snap.get('fans') or {})} ventilateur(s)")
    return {"ok": True, "steps": steps, "snapshot": snap}


def _shquote(value: str) -> str:
    import shlex

    return shlex.quote(value or "")


# ================================================================== fabrique
async def client_for_host(host: dict):
    """Construit le client adapté au mode déclaré sur l'hôte."""
    meta = host.get("meta") or {}
    mode = meta.get("bmc_mode", "redfish")

    cred_id = host.get("bmc_credential_id") or host.get("credential_id")
    if not cred_id:
        raise IPMIError(f"Aucun identifiant BMC associé à « {host['name']} »")
    cred = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
    if not cred:
        raise IPMIError("Identifiant BMC introuvable")
    username = cred["username"] or "admin"
    password = decrypt(cred["secret_enc"]) or ""
    address = host.get("bmc_address") or host["address"]

    if mode == "ipmitool":
        proxy_id = meta.get("bmc_proxy_host_id")
        if not proxy_id:
            raise IPMIError("Aucune machine relais définie pour ipmitool")
        proxy = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": int(proxy_id)})
        if not proxy:
            raise IPMIError("Machine relais introuvable")
        return IpmitoolClient(proxy, address, username, password)

    return RedfishClient(address, username, password,
                         port=host.get("port") or 443,
                         secure=meta.get("bmc_secure", True))


def to_metrics(snapshot: dict[str, Any]) -> dict[str, float]:
    """Capteurs BMC → métriques persistables."""
    out: dict[str, float] = {}
    for name, value in (snapshot.get("temps") or {}).items():
        out[f"sensor.{re.sub(r'[^a-zA-Z0-9]+', '_', name).strip('_').lower()}"] = value
    for name, value in (snapshot.get("fans") or {}).items():
        out[f"fan.{re.sub(r'[^a-zA-Z0-9]+', '_', name).strip('_').lower()}"] = value
    if snapshot.get("power_watts"):
        out["power.total"] = float(snapshot["power_watts"])
    if snapshot.get("temps"):
        out["temp.cpu"] = max(snapshot["temps"].values())
    out["ipmi.on"] = 1.0 if snapshot.get("power_state") == "on" else 0.0
    return out
