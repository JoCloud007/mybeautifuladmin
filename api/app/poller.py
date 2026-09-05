"""Moteur de collecte : un worker asyncio par hôte, écriture batchée en base."""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import re
import time
from typing import Any

from .bus import bus
from .collectors.aiclient import client_for
from .collectors import docker as docker_col
from .collectors import homeassistant as hass_col
from .collectors import ipmi as ipmi_col
from .collectors import linux as linux_col
from .collectors import pbs as pbs_col
from .collectors import proxmox as pve_col
from .collectors import synology as syno_col
from .config import settings
from .db import execute, execute_many, fetch_all, fetch_one
from .ssh import SSHError, pool

log = logging.getLogger("mba.poller")

SLOW_EVERY = 300      # rafraîchissement des métadonnées (updates, OS, services)
CONTAINER_EVERY = 15  # inventaire des conteneurs

# Seules ces valeurs scalaires partent en base ; le reste ne vit que sur le bus.
PERSISTED_PREFIXES = (
    "cpu.usage", "cpu.user", "cpu.system", "cpu.iowait", "mem.percent", "mem.used",
    "swap.percent", "load.1", "load.5", "load.15", "net.rx", "net.tx",
    "disk.read", "disk.write", "disk.percent", "temp.", "gpu.", "ollama.", "ai.",
    "docker.containers", "docker.cpu", "docker.mem", "pve.guests", "pve.node",
    "sensor.", "fan.", "power.", "ipmi.", "pbs.", "hass.",
)

SENSOR_RE = re.compile(r"[^a-zA-Z0-9]+")


def sensor_metrics(sample: dict[str, Any]) -> dict[str, float]:
    """Aplatit tous les capteurs relevés en métriques persistables.

    Les capteurs varient d'une machine à l'autre (thermal_zone, hwmon, SMART,
    IPMI…) : on les normalise en « sensor.<slug> » pour pouvoir les tracer et
    les comparer dans la vue Températures.
    """
    out: dict[str, float] = {}
    for name, value in (sample.get("temps") or {}).items():
        if isinstance(value, (int, float)) and 0 < value < 150:
            out[f"sensor.{SENSOR_RE.sub('_', name).strip('_').lower()}"] = float(value)
    for disk in sample.get("smart") or []:
        if isinstance(disk.get("temp"), (int, float)) and disk["temp"] > 0:
            out[f"sensor.disk_{disk['device']}"] = float(disk["temp"])
    for disk in sample.get("disks") or []:  # Synology
        if isinstance(disk.get("temp"), (int, float)) and disk["temp"] > 0:
            out[f"sensor.disk_{SENSOR_RE.sub('_', str(disk.get('id') or disk.get('name'))).lower()}"] = float(disk["temp"])
    for name, value in (sample.get("fans") or {}).items():
        if isinstance(value, (int, float)):
            out[f"fan.{SENSOR_RE.sub('_', name).strip('_').lower()}"] = float(value)
    for name, value in (sample.get("power_sensors") or {}).items():
        if isinstance(value, (int, float)):
            out[f"power.{SENSOR_RE.sub('_', name).strip('_').lower()}"] = float(value)
    for index, gpu in enumerate(sample.get("gpus") or []):
        if gpu.get("temp"):
            out[f"sensor.gpu{index}"] = float(gpu["temp"])
        if gpu.get("fan"):
            out[f"fan.gpu{index}"] = float(gpu["fan"])
        if gpu.get("power"):
            out[f"power.gpu{index}"] = float(gpu["power"])
    return out


def _persistable(metric: str, value: Any) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    return metric.startswith(PERSISTED_PREFIXES)


class MetricWriter:
    """Accumule les points et les insère par paquets."""

    def __init__(self, flush_interval: float = 2.0, max_batch: int = 2000) -> None:
        self.rows: list[dict] = []
        self.flush_interval = flush_interval
        self.max_batch = max_batch
        self._task: asyncio.Task | None = None

    def add(self, host_id: int, when: float, sample: dict[str, Any]) -> None:
        for metric, value in sample.items():
            if _persistable(metric, value):
                self.rows.append({"host_id": host_id, "epoch": when, "metric": metric, "value": float(value)})

    async def flush(self) -> None:
        if not self.rows:
            return
        rows, self.rows = self.rows[: self.max_batch], self.rows[self.max_batch:]
        try:
            await execute_many(
                "INSERT INTO metrics (time, host_id, metric, value) "
                "VALUES (to_timestamp(:epoch), :host_id, :metric, :value)",
                rows,
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("Écriture des métriques échouée (%d points): %s", len(rows), exc)

    async def run(self) -> None:
        while True:
            await asyncio.sleep(self.flush_interval)
            await self.flush()

    def start(self) -> None:
        self._task = asyncio.create_task(self.run(), name="metric-writer")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
        await self.flush()


writer = MetricWriter()


class HostWorker:
    def __init__(self, host: dict) -> None:
        self.host = host
        self.id = host["id"]
        self.sampler = linux_col.LinuxSampler()
        self.task: asyncio.Task | None = None
        self.last_slow = 0.0
        self.last_containers = 0.0
        self.fail_streak = 0

    # ---------------------------------------------------------------- cycle
    async def run(self) -> None:
        # Décalage initial pour ne pas taper tous les hôtes à la même seconde.
        await asyncio.sleep((self.id % 10) * 0.3)
        while True:
            started = time.time()
            try:
                await self.cycle()
                self.fail_streak = 0
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001
                await self.mark_down(exc)
            interval = settings.poll_interval * (1 if self.fail_streak == 0 else min(self.fail_streak, 6))
            await asyncio.sleep(max(1.0, interval - (time.time() - started)))

    async def cycle(self) -> None:
        kind = self.host["kind"]
        now = time.time()

        if kind == "linux":
            sample = await self.collect_linux(now)
        elif kind == "proxmox":
            sample = await self.collect_proxmox()
        elif kind == "synology":
            sample = await self.collect_synology()
        elif kind == "docker":
            sample = await self.collect_docker_host(now)
        elif kind == "ipmi":
            sample = await self.collect_ipmi()
        elif kind == "pbs":
            sample = await self.collect_pbs()
        elif kind == "homeassistant":
            sample = await self.collect_homeassistant()
        else:
            sample = await self.collect_generic()

        sample.update(sensor_metrics(sample))
        sample["_ts"] = now
        sample["_host_id"] = self.id
        sample["_name"] = self.host["name"]
        sample["_kind"] = kind

        writer.add(self.id, now, sample)
        bus.publish(f"metrics.{self.id}", sample)
        await self.mark_up()

    # ------------------------------------------------------------- collectes
    async def collect_linux(self, now: float) -> dict:
        raw = await pool.run(self.host, linux_col.PROBE, timeout=25)
        sample = self.sampler.parse(raw)

        if now - self.last_slow > SLOW_EVERY:
            self.last_slow = now
            with contextlib.suppress(SSHError):
                meta = linux_col.parse_slow(await pool.run(self.host, linux_col.SLOW_PROBE, timeout=90))
                await self.merge_meta(meta)
                sample["meta"] = meta

        meta = self.host.get("meta") or {}
        if meta.get("has_docker") and now - self.last_containers > CONTAINER_EVERY:
            self.last_containers = now
            with contextlib.suppress(SSHError, RuntimeError):
                containers = await docker_col.collect(self.host)
                await self.save_containers(containers)
                sample.update(await docker_col.collect_stats_metrics(containers))
                sample["containers"] = containers
        return sample

    async def collect_proxmox(self) -> dict:
        client = await pve_col.client_for_host(self.host)
        try:
            snap = await client.snapshot()
        finally:
            await client.close()
        sample = dict(snap["metrics"])
        sample["nodes"] = snap["nodes"]
        sample["guests"] = snap["guests"]
        sample["storages"] = snap["storages"]
        await self.merge_meta({
            "nodes": [n["node"] for n in snap["nodes"]],
            "version": (snap["nodes"][0]["version"] if snap["nodes"] else ""),
        })
        await self.save_guests(snap["guests"])
        return sample

    async def collect_synology(self) -> dict:
        client = await syno_col.client_for_host(self.host)
        try:
            snap = await client.snapshot()
        finally:
            await client.logout()
        sample = dict(snap["metrics"])
        sample["volumes"] = snap["volumes"]
        sample["disks"] = snap["disks"]
        sample["pools"] = snap["pools"]
        sample["info"] = snap["info"]
        await self.merge_meta(snap["info"])
        return sample

    async def collect_docker_host(self, now: float) -> dict:
        # Un hôte Docker distant est aussi une machine Linux : on veut ses
        # métriques système, pas seulement l'inventaire de ses conteneurs.
        sample: dict = {}
        if self.host["address"] not in ("local", "127.0.0.1", "localhost"):
            with contextlib.suppress(SSHError):
                sample = await self.collect_linux(now)

        if now - self.last_containers > CONTAINER_EVERY or "containers" not in sample:
            self.last_containers = now
            containers = await docker_col.collect(self.host)
            await self.save_containers(containers)
            sample.update(await docker_col.collect_stats_metrics(containers))
            sample["containers"] = containers
        return sample

    async def collect_ipmi(self) -> dict:
        client = await ipmi_col.client_for_host(self.host)
        snap = await client.snapshot()
        sample = dict(ipmi_col.to_metrics(snap))
        sample["bmc"] = snap
        sample["temps"] = snap.get("temps") or {}
        sample["fans"] = snap.get("fans") or {}
        await self.merge_meta({k: v for k, v in snap.items() if k in
                               ("model", "manufacturer", "serial", "bios", "bmc_firmware",
                                "bmc_model", "cpu_model", "cpu_count", "mem_total")
                               and v})
        return sample

    async def collect_pbs(self) -> dict:
        client = await pbs_col.client_for_host(self.host)
        try:
            snap = await client.snapshot()
        finally:
            await client.close()
        sample = dict(snap["metrics"])
        sample["datastores"] = snap["datastores"]
        sample["groups"] = snap["groups"]
        sample["tasks"] = snap["tasks"]
        return sample

    async def collect_homeassistant(self) -> dict:
        client = await hass_col.client_for_host(self.host)
        snap = await client.snapshot()
        sample = dict(snap["metrics"])
        sample["entities"] = snap["entities"]
        sample["hass"] = snap["summary"]
        sample["by_domain"] = snap["by_domain"]
        await self.merge_meta({"version": snap.get("version"), "location": snap.get("location")})
        return sample

    async def collect_generic(self) -> dict:
        from .discovery import probe_port

        port = self.host.get("port") or 80
        alive = await probe_port(self.host["address"], port, timeout=3.0)
        if not alive:
            raise RuntimeError(f"Port {port} injoignable")
        return {"up": 1.0}

    # ------------------------------------------------------------ persistance
    async def merge_meta(self, meta: dict) -> None:
        if not meta:
            return
        merged = {**(self.host.get("meta") or {}), **meta}
        self.host["meta"] = merged
        await execute(
            "UPDATE hosts SET meta = meta || CAST(:meta AS jsonb) WHERE id = :id",
            {"id": self.id, "meta": json.dumps(meta, default=str)},
        )

    async def save_containers(self, containers: list[dict]) -> None:
        if containers:
            await execute_many(
                """INSERT INTO containers (host_id, ext_id, name, kind, image, state, status,
                                           ports, stats, labels, project, service, updated_at)
                   VALUES (:host_id, :ext_id, :name, :kind, :image, :state, :status,
                           CAST(:ports AS jsonb), CAST(:stats AS jsonb), CAST(:labels AS jsonb),
                           :project, :service, now())
                   ON CONFLICT (host_id, ext_id) DO UPDATE SET
                     name = EXCLUDED.name, image = EXCLUDED.image, state = EXCLUDED.state,
                     status = EXCLUDED.status, ports = EXCLUDED.ports, stats = EXCLUDED.stats,
                     labels = EXCLUDED.labels, project = EXCLUDED.project,
                     service = EXCLUDED.service, updated_at = now()""",
                [{
                    "host_id": self.id, "ext_id": c["ext_id"], "name": c["name"], "kind": c.get("kind", "docker"),
                    "image": c.get("image", ""), "state": c.get("state", ""), "status": c.get("status", ""),
                    "ports": json.dumps(c.get("ports") or []), "stats": json.dumps(c.get("stats") or {}),
                    "labels": json.dumps(c.get("labels") or {}),
                    "project": c.get("project"), "service": c.get("service"),
                } for c in containers],
            )
        await execute(
            "DELETE FROM containers WHERE host_id = :id AND kind = 'docker' "
            "AND NOT (ext_id = ANY(CAST(:keep AS text[])))",
            {"id": self.id, "keep": [c["ext_id"] for c in containers] or [""]},
        )

    async def save_guests(self, guests: list[dict]) -> None:
        if not guests:
            return
        await execute_many(
            """INSERT INTO containers (host_id, ext_id, name, kind, image, state, status, stats, updated_at)
               VALUES (:host_id, :ext_id, :name, :kind, :image, :state, :status, CAST(:stats AS jsonb), now())
               ON CONFLICT (host_id, ext_id) DO UPDATE SET
                 name = EXCLUDED.name, state = EXCLUDED.state, status = EXCLUDED.status,
                 stats = EXCLUDED.stats, updated_at = now()""",
            [{
                "host_id": self.id, "ext_id": f"{g['type']}/{g['vmid']}", "name": g["name"],
                "kind": g["type"], "image": g.get("node", ""), "state": g["status"],
                "status": f"{g['status']} · {g['cpu']}% CPU",
                "stats": json.dumps({"cpu": g["cpu"], "mem": g["mem"], "mem_limit": g["maxmem"],
                                     "mem_percent": g["mem_percent"], "node": g.get("node"),
                                     "vmid": g["vmid"], "uptime": g.get("uptime", 0)}),
            } for g in guests],
        )

    async def mark_up(self) -> None:
        if self.host.get("status") != "online":
            self.host["status"] = "online"
            await execute(
                "UPDATE hosts SET status='online', last_seen=now(), last_error=NULL WHERE id=:id",
                {"id": self.id},
            )
            bus.publish("host.status", {"host_id": self.id, "status": "online", "name": self.host["name"]})
            await log_event(self.id, "info", "collecte",
                            f"{self.host['name']} est de nouveau joignable",
                            {"apres_tentatives": self.fail_streak})
            from . import notify
            await notify.dispatch(
                "host_up", f"{self.host['name']} de nouveau joignable",
                notify.format_event(self.host["name"], "info",
                                    "La collecte a repris.",
                                    {"tentatives": self.fail_streak}),
                dedupe_key=f"host_up:{self.id}",
            )
        else:
            await execute("UPDATE hosts SET last_seen=now() WHERE id=:id", {"id": self.id})

    async def mark_down(self, exc: Exception) -> None:
        self.fail_streak += 1
        message = str(exc)[:1500] or type(exc).__name__
        pool.drop(self.id)
        detail = {
            "type_erreur": type(exc).__name__,
            "adresse": f"{self.host['address']}:{self.host.get('port') or '?'}",
            "type_hote": self.host["kind"],
            "tentatives": self.fail_streak,
            "message": message,
        }
        if self.host.get("status") != "offline":
            self.host["status"] = "offline"
            await execute(
                "UPDATE hosts SET status='offline', last_error=:err WHERE id=:id",
                {"id": self.id, "err": message},
            )
            bus.publish("host.status", {"host_id": self.id, "status": "offline",
                                        "name": self.host["name"], "error": message})
            await log_event(self.id, "critical", "collecte",
                            f"{self.host['name']} injoignable — {message.splitlines()[0][:180]}",
                            detail)
            from . import notify
            await notify.dispatch(
                "host_down", f"{self.host['name']} injoignable",
                notify.format_event(self.host["name"], "critique",
                                    message.splitlines()[0][:300], detail),
                dedupe_key=f"host_down:{self.id}",
            )
        else:
            await execute("UPDATE hosts SET last_error=:err WHERE id=:id", {"id": self.id, "err": message})
            # Toutes les 12 tentatives, on rappelle que la panne dure.
            if self.fail_streak % 12 == 0:
                await log_event(self.id, "warning", "collecte",
                                f"{self.host['name']} toujours injoignable "
                                f"({self.fail_streak} tentatives)", detail)
        log.info("Hôte %s KO (%s tentative(s)): %s", self.host["name"], self.fail_streak, message)


async def log_event(host_id: int | None, level: str, source: str, message: str, data: dict | None = None) -> None:
    await execute(
        "INSERT INTO events (host_id, level, source, message, data) "
        "VALUES (:h, :l, :s, :m, CAST(:d AS jsonb))",
        {"h": host_id, "l": level, "s": source, "m": message, "d": json.dumps(data or {}, default=str)},
    )
    bus.publish("event", {"host_id": host_id, "level": level, "source": source,
                          "message": message, "time": time.time()})


# --------------------------------------------------------------- superviseur
class Supervisor:
    def __init__(self) -> None:
        self.workers: dict[int, HostWorker] = {}
        self.task: asyncio.Task | None = None

    async def sync(self) -> None:
        hosts = await fetch_all("SELECT * FROM hosts WHERE enabled = true ORDER BY id")
        wanted = {h["id"]: h for h in hosts}

        for host_id in list(self.workers):
            if host_id not in wanted:
                await self.stop_worker(host_id)

        for host_id, host in wanted.items():
            worker = self.workers.get(host_id)
            if worker is None:
                worker = HostWorker(host)
                worker.task = asyncio.create_task(worker.run(), name=f"host-{host_id}")
                self.workers[host_id] = worker
            else:
                # On garde l'état d'échantillonnage, on rafraîchit la config.
                worker.host.update({k: v for k, v in host.items() if k != "meta"})
                worker.host["meta"] = host.get("meta") or worker.host.get("meta") or {}

    async def stop_worker(self, host_id: int) -> None:
        worker = self.workers.pop(host_id, None)
        if worker and worker.task:
            worker.task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker.task
        pool.drop(host_id)

    async def loop(self) -> None:
        while True:
            try:
                await self.sync()
            except Exception as exc:  # noqa: BLE001
                log.warning("Synchronisation des workers échouée: %s", exc)
            await asyncio.sleep(10)

    async def start(self) -> None:
        writer.start()
        self.task = asyncio.create_task(self.loop(), name="supervisor")

    async def stop(self) -> None:
        if self.task:
            self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.task
        for host_id in list(self.workers):
            await self.stop_worker(host_id)
        await writer.stop()
        await pool.close()

    async def refresh_now(self, host_id: int) -> None:
        """Force un cycle immédiat après une action (reboot, restart...)."""
        worker = self.workers.get(host_id)
        if worker:
            with contextlib.suppress(Exception):
                worker.last_slow = 0
                worker.last_containers = 0
                await worker.cycle()


supervisor = Supervisor()


# ------------------------------------------------------------- sondes web + IA
async def check_services() -> None:
    """Boucle de supervision des services web."""
    import httpx

    while True:
        try:
            services = await fetch_all("SELECT * FROM services WHERE enabled = true")
            now = time.time()
            due = [s for s in services
                   if not s["last_checked"] or now - s["last_checked"].timestamp() >= s["interval_s"]]
            if due:
                async with httpx.AsyncClient(verify=False, timeout=15.0, follow_redirects=True) as client:
                    await asyncio.gather(*(_check_service(client, s) for s in due), return_exceptions=True)
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle services: %s", exc)
        await asyncio.sleep(5)


async def _check_service(client, service: dict) -> None:
    started = time.perf_counter()
    ok, code, error = False, None, None
    try:
        resp = await client.request(service["method"] or "GET", service["url"])
        code = resp.status_code
        ok = code == service["expect_status"]
        if ok and service.get("expect_body"):
            ok = service["expect_body"] in resp.text
            if not ok:
                error = "Contenu attendu absent"
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"[:200]
    latency = (time.perf_counter() - started) * 1000

    status = "up" if ok else "down"
    previous = service.get("status")
    await execute(
        "UPDATE services SET status=:st, last_latency_ms=:lat, last_checked=now() WHERE id=:id",
        {"st": status, "lat": latency, "id": service["id"]},
    )
    await execute(
        "INSERT INTO service_checks (time, service_id, ok, status_code, latency_ms, error) "
        "VALUES (now(), :sid, :ok, :code, :lat, :err)",
        {"sid": service["id"], "ok": ok, "code": code, "lat": latency, "err": error},
    )
    bus.publish("service", {"id": service["id"], "name": service["name"], "status": status,
                            "latency_ms": round(latency, 1), "status_code": code, "error": error})
    if previous in ("up", "down") and previous != status:
        await log_event(service.get("host_id"), "warning" if not ok else "info", "service",
                        f"{service['name']} est {'DOWN' if not ok else 'de nouveau UP'}"
                        + (f" — {error}" if error else ""))
        if not ok:
            from . import notify
            await notify.dispatch(
                "service_down", f"{service['name']} ne répond plus",
                notify.format_event(None, "avertissement",
                                    f"{service['name']} ({service['url']}) est injoignable.",
                                    {"erreur": error or f"code {code}"}),
                dedupe_key=f"service:{service['id']}",
            )


async def poll_ai_endpoints() -> None:
    while True:
        try:
            endpoints = await fetch_all("SELECT * FROM ai_endpoints WHERE enabled = true")
            for ep in endpoints:
                try:
                    snap = await client_for(ep).snapshot()
                    await execute(
                        "UPDATE ai_endpoints SET status='online', meta = CAST(:m AS jsonb) WHERE id=:id",
                        {"id": ep["id"], "m": json.dumps({"version": snap["version"],
                                                          "models": len(snap["models"])}, default=str)},
                    )
                    bus.publish(f"ai.{ep['id']}", {"id": ep["id"], "name": ep["name"], "status": "online", **snap})
                    if ep.get("host_id"):
                        writer.add(ep["host_id"], time.time(), snap["metrics"])
                except Exception as exc:  # noqa: BLE001
                    await execute("UPDATE ai_endpoints SET status='offline' WHERE id=:id", {"id": ep["id"]})
                    bus.publish(f"ai.{ep['id']}", {"id": ep["id"], "name": ep["name"],
                                                   "status": "offline", "error": str(exc)[:200]})
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle IA: %s", exc)
        await asyncio.sleep(10)


# ------------------------------------------------------------------- alertes
async def evaluate_alerts() -> None:
    while True:
        await asyncio.sleep(30)
        try:
            rules = await fetch_all("SELECT * FROM alert_rules WHERE enabled = true")
            for rule in rules:
                await _evaluate_rule(rule)
        except Exception as exc:  # noqa: BLE001
            log.warning("Évaluation des alertes: %s", exc)


async def _evaluate_rule(rule: dict) -> None:
    op = rule["operator"] if rule["operator"] in (">", "<", ">=", "<=") else ">"
    rows = await fetch_all(
        f"""
        SELECT m.host_id, h.name, avg(m.value) AS value
        FROM metrics m JOIN hosts h ON h.id = m.host_id
        WHERE m.metric = :metric
          AND m.time > now() - make_interval(secs => :window)
          AND (CAST(:host_id AS INTEGER) IS NULL OR m.host_id = :host_id)
        GROUP BY m.host_id, h.name
        HAVING avg(m.value) {op} :threshold
        """,
        {"metric": rule["metric"], "window": rule["for_s"],
         "host_id": rule["host_id"], "threshold": rule["threshold"]},
    )
    firing_hosts = {r["host_id"]: r for r in rows}

    active = await fetch_all(
        "SELECT * FROM alerts WHERE rule_id = :rid AND state = 'firing'", {"rid": rule["id"]}
    )
    active_by_host = {a["host_id"]: a for a in active}

    for host_id, row in firing_hosts.items():
        if host_id in active_by_host:
            continue
        message = f"{rule['name']} sur {row['name']} : {rule['metric']} = {row['value']:.1f} ({op} {rule['threshold']})"
        await execute(
            "INSERT INTO alerts (rule_id, host_id, severity, message, value) VALUES (:r,:h,:s,:m,:v)",
            {"r": rule["id"], "h": host_id, "s": rule["severity"], "m": message, "v": row["value"]},
        )
        await log_event(host_id, rule["severity"], "alert", message)
        bus.publish("alert", {"host_id": host_id, "severity": rule["severity"], "message": message})
        from . import notify
        await notify.dispatch(
            "alert_firing", message[:120],
            notify.format_event(row["name"], rule["severity"], message,
                                {"métrique": rule["metric"], "seuil": rule["threshold"]}),
            dedupe_key=f"alert:{rule['id']}:{host_id}",
        )

    for host_id, alert in active_by_host.items():
        if host_id not in firing_hosts:
            await execute(
                "UPDATE alerts SET state='resolved', resolved_at=now() WHERE id=:id", {"id": alert["id"]}
            )
            await log_event(host_id, "info", "alert", f"Résolu : {alert['message']}")
            bus.publish("alert", {"host_id": host_id, "severity": "info",
                                  "message": f"Résolu : {alert['message']}", "resolved": True})
