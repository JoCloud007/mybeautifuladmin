from __future__ import annotations

import re
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status

from ..bus import bus
from ..db import fetch_all
from ..security import current_user

router = APIRouter(prefix="/monitoring", tags=["monitoring"])

RANGES = {"5m": 300, "15m": 900, "1h": 3600, "6h": 21600, "24h": 86400,
          "7d": 604800, "30d": 2592000}
METRIC_RE = re.compile(r"^[A-Za-z0-9._/\-]+$")

# Métriques proposées par défaut dans le sélecteur, avec leur unité.
CATALOG: list[dict[str, Any]] = [
    {"metric": "cpu.usage", "label": "Processeur", "unit": "%", "max": 100},
    {"metric": "mem.percent", "label": "Mémoire", "unit": "%", "max": 100},
    {"metric": "swap.percent", "label": "Swap", "unit": "%", "max": 100},
    {"metric": "disk.percent", "label": "Stockage", "unit": "%", "max": 100},
    {"metric": "load.1", "label": "Charge (1 min)", "unit": ""},
    {"metric": "net.rx", "label": "Réseau — réception", "unit": "B/s"},
    {"metric": "net.tx", "label": "Réseau — émission", "unit": "B/s"},
    {"metric": "disk.read", "label": "Disque — lecture", "unit": "B/s"},
    {"metric": "disk.write", "label": "Disque — écriture", "unit": "B/s"},
    {"metric": "temp.cpu", "label": "Température CPU", "unit": "°C"},
    {"metric": "gpu.busy", "label": "GPU — occupation", "unit": "%", "max": 100},
    {"metric": "gpu.vram_percent", "label": "GPU — VRAM", "unit": "%", "max": 100},
    {"metric": "power.total", "label": "Consommation", "unit": "W"},
    {"metric": "docker.containers.running", "label": "Conteneurs actifs", "unit": ""},
]


@router.get("/catalog")
async def catalog(user: dict = Depends(current_user)) -> dict:
    """Hôtes supervisés et métriques réellement disponibles pour chacun."""
    hosts = await fetch_all(
        "SELECT id, name, kind, status, coalesce(tags, '{}') AS tags "
        "FROM hosts WHERE enabled ORDER BY kind, name"
    )
    available = await fetch_all(
        """SELECT host_id, metric FROM metrics
           WHERE time > now() - interval '30 minutes'
           GROUP BY host_id, metric"""
    )
    by_host: dict[int, list[str]] = {}
    for row in available:
        by_host.setdefault(row["host_id"], []).append(row["metric"])

    known = {entry["metric"] for entry in CATALOG}
    extra = sorted({m for metrics in by_host.values() for m in metrics} - known)
    return {
        "hosts": [{**h, "metrics": sorted(by_host.get(h["id"], []))} for h in hosts],
        "catalog": CATALOG,
        "extra_metrics": extra,
        "ranges": list(RANGES),
    }


@router.get("/series")
async def series(
    hosts: str = Query(..., description="Identifiants d'hôtes séparés par des virgules"),
    metrics: str = Query(...),
    range_: str = Query("1h", alias="range"),
    points: int = Query(300, ge=10, le=2000),
    user: dict = Depends(current_user),
) -> dict:
    """Séries multi-hôtes alignées, pour superposer plusieurs machines."""
    host_ids = [int(h) for h in hosts.split(",") if h.strip().isdigit()]
    names = [m.strip() for m in metrics.split(",") if m.strip()]
    if not host_ids or not names:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Hôtes et métriques requis")
    if any(not METRIC_RE.match(m) for m in names):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Nom de métrique invalide")
    window = RANGES.get(range_)
    if window is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Plage inconnue : {range_}")

    bucket = max(1, window // points)
    source, time_col, value_col = (
        ("metrics_1m", "bucket", "avg_value") if window > 21600 else ("metrics", "time", "value")
    )
    rows = await fetch_all(
        f"""
        SELECT extract(epoch FROM time_bucket(make_interval(secs => :bucket), {time_col})) AS t,
               host_id, metric, avg({value_col}) AS v
        FROM {source}
        WHERE host_id = ANY(CAST(:hosts AS integer[]))
          AND metric = ANY(CAST(:names AS text[]))
          AND {time_col} > now() - make_interval(secs => :window)
        GROUP BY t, host_id, metric
        ORDER BY t
        """,
        {"bucket": bucket, "hosts": host_ids, "names": names, "window": window},
    )

    out: dict[str, list[list[float]]] = {}
    for row in rows:
        key = f"{row['host_id']}:{row['metric']}"
        out.setdefault(key, []).append([float(row["t"]), float(row["v"])])

    labels = {h["id"]: h["name"] for h in
              await fetch_all("SELECT id, name FROM hosts WHERE id = ANY(CAST(:ids AS integer[]))",
                              {"ids": host_ids})}
    return {"range": range_, "bucket": bucket, "series": out, "hosts": labels}


# Métriques dérivées : traçables, mais ce ne sont pas des sondes physiques.
AGGREGATES = {"fan.max", "fan.count", "temp.disks_max", "power.total"}


@router.get("/sensors")
async def sensors(user: dict = Depends(current_user)) -> dict:
    """Tous les capteurs thermiques, ventilateurs et puissances du parc."""
    live = bus.latest("metrics.")
    readings: list[dict[str, Any]] = []

    for sample in live.values():
        host_id, host_name = sample.get("_host_id"), sample.get("_name")
        if not host_id:
            continue
        for metric, value in sample.items():
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                continue
            if metric in AGGREGATES:
                continue
            if metric.startswith("sensor."):
                kind = "temperature"
            elif metric.startswith("fan."):
                kind = "fan"
            elif metric.startswith("power."):
                kind = "power"
            else:
                continue
            name = metric.split(".", 1)[1]
            readings.append({
                "host_id": host_id,
                "host_name": host_name,
                "metric": metric,
                "name": name,
                "kind": kind,
                "value": float(value),
                "label": _pretty(name),
                "critical": kind == "temperature" and value >= 85,
                "warning": kind == "temperature" and 70 <= value < 85,
            })

    readings.sort(key=lambda r: (r["host_name"] or "", r["kind"], r["name"]))
    temps = [r for r in readings if r["kind"] == "temperature"]
    return {
        "readings": readings,
        "summary": {
            "sensors": len(readings),
            "temperatures": len(temps),
            "hottest": max(temps, key=lambda r: r["value"]) if temps else None,
            "critical": len([r for r in temps if r["critical"]]),
            "warning": len([r for r in temps if r["warning"]]),
            "fans": len([r for r in readings if r["kind"] == "fan"]),
            "power_total": round(sum(r["value"] for r in readings if r["kind"] == "power"), 1),
        },
    }


# Étiquettes lisibles pour les noms de capteurs bruts les plus courants.
PRETTY = {
    "x86_pkg_temp": "Package CPU",
    "acpitz": "Carte mère (ACPI)",
    "coretemp_temp1": "Cœur CPU 1",
    "k10temp_temp1": "CPU (Tctl)",
    "nvme_composite": "SSD NVMe",
    "total": "Total",
}


def _pretty(name: str) -> str:
    if name in PRETTY:
        return PRETTY[name]
    if name.startswith("disk_"):
        return f"Disque {name[5:].upper()}"
    if name.startswith("gpu"):
        return f"GPU {name[3:] or ''}".strip()
    if name.startswith("cpu"):
        return "Processeur"
    return name.replace("_", " ").capitalize()
