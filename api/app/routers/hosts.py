from __future__ import annotations

import asyncio
import json
import re
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field

from .. import actions as act
from ..bus import bus
from ..db import execute, fetch_all, fetch_one
from ..poller import supervisor
from ..security import current_user
from ..ssh import pool

router = APIRouter(tags=["infra"])

HostKind = Literal["linux", "proxmox", "synology", "docker", "pbs",
                   "homeassistant", "ipmi", "generic"]
RANGES = {"5m": 300, "15m": 900, "1h": 3600, "6h": 21600, "24h": 86400, "7d": 604800, "30d": 2592000}
METRIC_RE = re.compile(r"^[A-Za-z0-9._/\-]+$")


# ------------------------------------------------------------------- schémas
class HostIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    kind: HostKind = "linux"
    address: str = Field(min_length=1)
    port: int | None = None
    credential_id: int | None = None
    tags: list[str] = []
    enabled: bool = True
    meta: dict[str, Any] = {}


class HostPatch(BaseModel):
    name: str | None = None
    kind: HostKind | None = None
    address: str | None = None
    port: int | None = None
    credential_id: int | None = None
    tags: list[str] | None = None
    enabled: bool | None = None
    meta: dict[str, Any] | None = None


CredentialKind = Literal["ssh_password", "ssh_key", "api_token", "token", "basic", "ovh_api"]

# Types qui n'ont pas d'utilisateur : le secret se suffit à lui-même.
SECRET_ONLY = {"token"}


class CredentialIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    kind: CredentialKind
    username: str | None = None
    secret: str | None = None
    passphrase: str | None = None


class CredentialPatch(BaseModel):
    """Le secret n'est réécrit que s'il est fourni : laisser vide le conserve."""

    name: str | None = None
    kind: CredentialKind | None = None
    username: str | None = None
    secret: str | None = None
    passphrase: str | None = None


class CommandIn(BaseModel):
    command: str = Field(min_length=1, max_length=4000)
    timeout: int = 120


class ServiceActionIn(BaseModel):
    service: str
    action: Literal["restart", "start", "stop", "reload", "status"]


class GuestActionIn(BaseModel):
    vmid: int
    kind: Literal["qemu", "lxc"]
    action: Literal["start", "stop", "shutdown", "reboot", "suspend", "resume", "reset"]
    node: str | None = None


DEFAULT_PORTS = {"linux": 22, "proxmox": 8006, "synology": 5001, "docker": 22,
                 "pbs": 8007, "homeassistant": 8123, "ipmi": 443, "generic": 80}


# ----------------------------------------------------------------- overview
@router.get("/overview")
async def overview(user: dict = Depends(current_user)) -> dict:
    hosts = await fetch_all("SELECT * FROM hosts ORDER BY name")
    live = bus.latest("metrics.")
    enriched = [_enrich(h, live) for h in hosts]

    services = await fetch_all("SELECT status, count(*) AS n FROM services WHERE enabled GROUP BY status")
    alerts = await fetch_all(
        "SELECT a.*, h.name AS host_name FROM alerts a LEFT JOIN hosts h ON h.id = a.host_id "
        "WHERE a.state = 'firing' ORDER BY a.started_at DESC LIMIT 50"
    )
    containers = await fetch_one(
        "SELECT count(*) FILTER (WHERE state IN ('running')) AS running, count(*) AS total FROM containers"
    )
    events = await fetch_all(
        "SELECT e.time, e.level, e.source, e.message, h.name AS host_name "
        "FROM events e LEFT JOIN hosts h ON h.id = e.host_id ORDER BY e.time DESC LIMIT 30"
    )

    online = [h for h in enriched if h["status"] == "online"]
    return {
        "hosts": enriched,
        "summary": {
            "hosts_total": len(hosts),
            "hosts_online": len(online),
            "hosts_offline": len([h for h in enriched if h["status"] == "offline"]),
            "containers_running": (containers or {}).get("running", 0),
            "containers_total": (containers or {}).get("total", 0),
            "services": {s["status"]: s["n"] for s in services},
            "alerts_firing": len(alerts),
            "updates_pending": sum((h.get("meta") or {}).get("updates", 0) for h in hosts),
            "cpu_avg": round(sum(h["live"].get("cpu.usage", 0) for h in online) / len(online), 1) if online else 0,
            "mem_avg": round(sum(h["live"].get("mem.percent", 0) for h in online) / len(online), 1) if online else 0,
        },
        "alerts": alerts,
        "events": events,
    }


def _enrich(host: dict, live: dict) -> dict:
    sample = live.get(f"metrics.{host['id']}", {})
    slim = {k: v for k, v in sample.items()
            if isinstance(v, (int, float)) and not isinstance(v, bool)}
    return {
        **host,
        "live": slim,
        "cores": sample.get("cpu.cores"),
        "filesystems": sample.get("filesystems"),
        "gpus": sample.get("gpus"),
    }


# -------------------------------------------------------------------- hosts
@router.get("/hosts")
async def list_hosts(user: dict = Depends(current_user)) -> list[dict]:
    hosts = await fetch_all("SELECT * FROM hosts ORDER BY kind, name")
    live = bus.latest("metrics.")
    return [_enrich(h, live) for h in hosts]


@router.post("/hosts", status_code=status.HTTP_201_CREATED)
async def create_host(payload: HostIn, user: dict = Depends(current_user)) -> dict:
    port = payload.port or DEFAULT_PORTS.get(payload.kind, 22)
    existing = await fetch_one(
        "SELECT id FROM hosts WHERE address=:a AND kind=:k AND port=:p",
        {"a": payload.address, "k": payload.kind, "p": port},
    )
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet hôte est déjà enregistré")
    host_id = await execute(
        """INSERT INTO hosts (name, kind, address, port, credential_id, tags, enabled, meta)
           VALUES (:name, :kind, :address, :port, :cred, :tags, :enabled, CAST(:meta AS jsonb))
           RETURNING id""",
        {"name": payload.name, "kind": payload.kind, "address": payload.address, "port": port,
         "cred": payload.credential_id, "tags": payload.tags, "enabled": payload.enabled,
         "meta": json.dumps(payload.meta)},
    )
    await supervisor.sync()
    return await get_host(host_id, user)


@router.get("/hosts/{host_id}")
async def get_host(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    live = bus.latest("metrics.")
    data = _enrich(host, live)
    sample = live.get(f"metrics.{host_id}", {})
    data["sample"] = {k: v for k, v in sample.items() if not k.startswith("_")}
    data["children"] = await fetch_all(
        "SELECT id, name, kind, status FROM hosts WHERE parent_id = :id", {"id": host_id}
    )
    return data


@router.patch("/hosts/{host_id}")
async def update_host(host_id: int, payload: HostPatch, user: dict = Depends(current_user)) -> dict:
    await _require_host(host_id)
    fields = payload.model_dump(exclude_unset=True)
    if not fields:
        return await get_host(host_id, user)
    sets, params = [], {"id": host_id}
    for key, value in fields.items():
        if key == "meta":
            sets.append("meta = CAST(:meta AS jsonb)")
            params["meta"] = json.dumps(value)
        else:
            sets.append(f"{key} = :{key}")
            params[key] = value
    await execute(f"UPDATE hosts SET {', '.join(sets)} WHERE id = :id", params)
    pool.drop(host_id)
    await supervisor.sync()
    return await get_host(host_id, user)


@router.delete("/hosts/{host_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_host(host_id: int, user: dict = Depends(current_user)) -> Response:
    await _require_host(host_id)
    await supervisor.stop_worker(host_id)
    await execute("DELETE FROM hosts WHERE id = :id", {"id": host_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/hosts/{host_id}/test")
async def test_host(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    try:
        if host["kind"] in ("linux", "docker"):
            out = await pool.run(host, "uname -a; echo OK", timeout=15)
            return {"ok": True, "detail": out.strip()[:400]}
        if host["kind"] == "proxmox":
            from ..collectors.proxmox import client_for_host
            client = await client_for_host(host)
            try:
                nodes = await client.get("/nodes")
            finally:
                await client.close()
            return {"ok": True, "detail": f"{len(nodes or [])} nœud(s) : "
                                          + ", ".join(n["node"] for n in (nodes or []))}
        if host["kind"] == "synology":
            from ..collectors.synology import client_for_host
            client = await client_for_host(host)
            try:
                info = await client.call("SYNO.Core.System", "info", 1)
            finally:
                await client.logout()
            return {"ok": True, "detail": f"{info.get('model')} · DSM {info.get('firmware_ver')}"}
        from ..discovery import probe_port
        ok = await probe_port(host["address"], host.get("port") or 80, timeout=4)
        return {"ok": ok, "detail": "Port ouvert" if ok else "Port fermé"}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "detail": str(exc)[:400]}


# ------------------------------------------------------------------ métriques
@router.get("/hosts/{host_id}/metrics")
async def host_metrics(
    host_id: int,
    metrics: str = Query(..., description="Liste séparée par des virgules"),
    range_: str = Query("1h", alias="range"),
    points: int = Query(300, ge=10, le=2000),
    user: dict = Depends(current_user),
) -> dict:
    await _require_host(host_id)
    names = [m.strip() for m in metrics.split(",") if m.strip()]
    if not names or any(not METRIC_RE.match(m) for m in names):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Nom de métrique invalide")
    window = RANGES.get(range_)
    if window is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Plage inconnue : {range_}")

    bucket = max(1, window // points)
    # Au-delà de 6 h on lit l'agrégat continu 1 min : même rendu, 60× moins de lignes.
    if window > 21600:
        sql = """
        SELECT extract(epoch FROM time_bucket(make_interval(secs => :bucket), bucket)) AS t,
               metric, avg(avg_value) AS v
        FROM metrics_1m
        WHERE host_id = :host_id
          AND metric = ANY(CAST(:names AS text[]))
          AND bucket > now() - make_interval(secs => :window)
        GROUP BY t, metric ORDER BY t
        """
    else:
        sql = """
        SELECT extract(epoch FROM time_bucket(make_interval(secs => :bucket), time)) AS t,
               metric, avg(value) AS v
        FROM metrics
        WHERE host_id = :host_id
          AND metric = ANY(CAST(:names AS text[]))
          AND time > now() - make_interval(secs => :window)
        GROUP BY t, metric ORDER BY t
        """
    rows = await fetch_all(sql, {"bucket": bucket, "host_id": host_id, "names": names, "window": window})
    series: dict[str, list[list[float]]] = {name: [] for name in names}
    for row in rows:
        series.setdefault(row["metric"], []).append([float(row["t"]), float(row["v"])])
    return {"range": range_, "bucket": bucket, "series": series}


@router.get("/hosts/{host_id}/live")
async def host_live(host_id: int, user: dict = Depends(current_user)) -> dict:
    await _require_host(host_id)
    return {
        "sample": bus.latest(f"metrics.{host_id}").get(f"metrics.{host_id}", {}),
        "history": bus.history(f"metrics.{host_id}"),
    }


# ----------------------------------------------------------------- conteneurs
@router.get("/containers")
async def all_containers(
    host_id: int | None = None,
    user: dict = Depends(current_user),
) -> list[dict]:
    sql = ("SELECT c.*, h.name AS host_name, h.kind AS host_kind, "
           "coalesce(h.tags, '{}') AS host_tags FROM containers c "
           "JOIN hosts h ON h.id = c.host_id")
    params: dict = {}
    if host_id:
        sql += " WHERE c.host_id = :h"
        params["h"] = host_id
    sql += " ORDER BY (c.state = 'running') DESC, c.name"
    return await fetch_all(sql, params)


@router.get("/containers/projects")
async def container_projects(user: dict = Depends(current_user)) -> dict:
    """Regroupement par pile docker compose, tous hôtes confondus."""
    rows = await fetch_all(
        """
        SELECT c.project, c.host_id, h.name AS host_name,
               count(*) AS total,
               count(*) FILTER (WHERE c.state = 'running') AS running,
               sum(coalesce((c.stats->>'cpu')::float, 0)) AS cpu,
               sum(coalesce((c.stats->>'mem')::float, 0)) AS mem,
               max(c.updated_at) AS updated_at
        FROM containers c JOIN hosts h ON h.id = c.host_id
        WHERE c.kind = 'docker'
        GROUP BY c.project, c.host_id, h.name
        ORDER BY (c.project IS NULL), c.project, h.name
        """
    )
    projects = [{
        "project": row["project"],
        "host_id": row["host_id"],
        "host_name": row["host_name"],
        "total": row["total"],
        "running": row["running"],
        "cpu": round(row["cpu"] or 0, 2),
        "mem": row["mem"] or 0,
        "updated_at": row["updated_at"],
    } for row in rows]
    named = [p for p in projects if p["project"]]
    return {
        "projects": projects,
        "summary": {
            "projects": len({p["project"] for p in named}),
            "orphans": sum(p["total"] for p in projects if not p["project"]),
        },
    }


@router.post("/hosts/{host_id}/projects/{project}/{action}")
async def project_action(host_id: int, project: str, action: str,
                         user: dict = Depends(current_user)) -> dict:
    """Applique une action à tous les conteneurs d'une pile compose."""
    if action not in ("start", "stop", "restart"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Action inconnue : {action}")
    host = await _require_host(host_id)
    members = await fetch_all(
        "SELECT ext_id, name, state FROM containers "
        "WHERE host_id = :h AND project = :p AND kind = 'docker' ORDER BY name",
        {"h": host_id, "p": project},
    )
    if not members:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pile introuvable sur cet hôte")

    done, errors = [], []
    for member in members:
        # Inutile de démarrer ce qui tourne déjà, ni d'arrêter ce qui est éteint.
        if action == "start" and member["state"] == "running":
            continue
        if action == "stop" and member["state"] != "running":
            continue
        try:
            await act.container_action(host, member["ext_id"], action, user["username"])
            done.append(member["name"])
        except Exception as exc:  # noqa: BLE001
            errors.append({"name": member["name"], "error": str(exc)[:200]})

    asyncio.create_task(act._refresh_containers_later(host_id))
    return {"project": project, "action": action, "done": done, "errors": errors}


@router.get("/hosts/{host_id}/containers/{ext_id}/logs")
async def container_logs(host_id: int, ext_id: str, lines: int = Query(200, ge=10, le=5000),
                         user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    from ..collectors.docker import container_logs as fetch_logs
    try:
        return {"logs": await fetch_logs(host, ext_id, lines)}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc


@router.post("/hosts/{host_id}/containers/{ext_id}/pull")
async def container_pull(host_id: int, ext_id: str, user: dict = Depends(current_user)) -> dict:
    """Récupère la dernière image d'un conteneur (sans le recréer)."""
    host = await _require_host(host_id)
    row = await fetch_one(
        "SELECT name, image, project, labels FROM containers WHERE host_id=:h AND ext_id=:e",
        {"h": host_id, "e": ext_id},
    )
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Conteneur introuvable")

    from ..collectors.docker import pull_image
    log_id = await execute(
        "INSERT INTO action_logs (host_id, target, action, status, username) "
        "VALUES (:h, :t, 'docker pull', 'running', :u) RETURNING id",
        {"h": host_id, "t": row["name"], "u": user["username"]},
    )
    try:
        result = await pull_image(host, row["image"])
    except Exception as exc:  # noqa: BLE001
        await execute("UPDATE action_logs SET status='failed', output=:o, ended_at=now() WHERE id=:id",
                      {"o": str(exc)[:4000], "id": log_id})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc

    await execute("UPDATE action_logs SET status='success', output=:o, ended_at=now() WHERE id=:id",
                  {"o": json.dumps(result, default=str)[:8000], "id": log_id})
    from ..poller import log_event
    await log_event(host_id, "info", "action",
                    f"Image {row['image']} : {result['detail']} ({row['name']})")
    return {
        **result,
        "container": row["name"],
        "project": row["project"],
        # Une image neuve n'est active qu'après recréation du conteneur.
        "needs_recreate": result["updated"],
    }


@router.post("/hosts/{host_id}/projects/{project}/update")
async def project_update(host_id: int, project: str,
                         user: dict = Depends(current_user)) -> dict:
    """`docker compose pull` + `up -d` : la seule voie sûre pour recréer une pile."""
    host = await _require_host(host_id)
    rows = await fetch_all(
        "SELECT labels FROM containers WHERE host_id=:h AND project=:p LIMIT 5",
        {"h": host_id, "p": project},
    )
    if not rows:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pile introuvable sur cet hôte")
    working_dir = next(
        (r["labels"].get("com.docker.compose.project.working_dir")
         for r in rows if (r["labels"] or {}).get("com.docker.compose.project.working_dir")),
        None,
    )

    from ..collectors.docker import compose_update
    log_id = await execute(
        "INSERT INTO action_logs (host_id, target, action, status, username) "
        "VALUES (:h, :t, 'compose update', 'running', :u) RETURNING id",
        {"h": host_id, "t": project, "u": user["username"]},
    )
    try:
        result = await compose_update(host, project, working_dir)
    except Exception as exc:  # noqa: BLE001
        await execute("UPDATE action_logs SET status='failed', output=:o, ended_at=now() WHERE id=:id",
                      {"o": str(exc)[:8000], "id": log_id})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:400]) from exc

    await execute("UPDATE action_logs SET status='success', output=:o, ended_at=now() WHERE id=:id",
                  {"o": result["output"][:16000], "id": log_id})
    from ..poller import log_event
    await log_event(host_id, "info", "action",
                    f"Pile « {project} » mise à jour sur {host['name']}")
    asyncio.create_task(act._refresh_containers_later(host_id, delay=4.0))
    return {**result, "log_id": log_id}


@router.post("/hosts/{host_id}/containers/{ext_id}/{action}")
async def container_action(host_id: int, ext_id: str, action: str,
                           user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    try:
        return await act.container_action(host, ext_id, action, user["username"])
    except (act.ActionError, ValueError) as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc


# ------------------------------------------------------------ ménage Docker
class PruneIn(BaseModel):
    targets: list[Literal["containers", "images", "images_all", "volumes",
                          "networks", "build_cache"]] = Field(min_length=1)


@router.get("/hosts/{host_id}/docker/usage")
async def docker_usage(host_id: int, user: dict = Depends(current_user)) -> dict:
    """Espace occupé et récupérable, avant de proposer une purge."""
    host = await _require_host(host_id)
    from ..collectors.docker import disk_usage
    try:
        usage = await disk_usage(host)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)[:300]) from exc
    return {
        "usage": usage,
        "reclaimable_total": sum((v or {}).get("reclaimable", 0) for v in usage.values()),
        "size_total": sum((v or {}).get("size", 0) for v in usage.values()),
    }


@router.post("/hosts/{host_id}/docker/prune")
async def docker_prune(host_id: int, payload: PruneIn,
                       user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    from ..collectors.docker import prune

    results, reclaimed, errors = [], 0.0, []
    for target in payload.targets:
        try:
            outcome = await prune(host, target)
            reclaimed += outcome.get("reclaimed") or 0
            results.append(outcome)
        except Exception as exc:  # noqa: BLE001
            errors.append({"target": target, "error": str(exc)[:200]})

    await execute(
        "INSERT INTO action_logs (host_id, target, action, status, output, username, ended_at) "
        "VALUES (:h, :t, 'docker prune', :s, :o, :u, now())",
        {"h": host_id, "t": ", ".join(payload.targets),
         "s": "success" if not errors else ("partial" if results else "failed"),
         "o": json.dumps({"results": results, "errors": errors}, default=str)[:20000],
         "u": user["username"]},
    )
    from ..poller import log_event
    await log_event(host_id, "info", "action",
                    f"Purge Docker sur {host['name']} : {reclaimed / 1e9:.2f} Go récupérés")
    asyncio.create_task(act._refresh_containers_later(host_id))
    return {"results": results, "errors": errors, "reclaimed": reclaimed}


# -------------------------------------------------------------------- actions
@router.post("/hosts/{host_id}/upgrade")
async def upgrade(host_id: int, user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    if host["kind"] not in ("linux", "docker"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "La mise à jour automatique ne couvre que les hôtes Linux")
    try:
        return await act.upgrade_host(host, user["username"])
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.post("/hosts/{host_id}/power/{action}")
async def power(host_id: int, action: str, user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    try:
        if host["kind"] == "synology":
            return await act.syno_action(host, action, user["username"])
        if host["kind"] == "proxmox":
            nodes = (host.get("meta") or {}).get("nodes") or []
            if not nodes:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Nœud Proxmox inconnu")
            return await act.pve_node_action(host, nodes[0], action, user["username"])
        return await act.power_action(host, action, user["username"])
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.post("/hosts/{host_id}/service")
async def service_control(host_id: int, payload: ServiceActionIn,
                          user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    try:
        return await act.service_action(host, payload.service, payload.action, user["username"])
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.post("/hosts/{host_id}/guest")
async def guest_control(host_id: int, payload: GuestActionIn,
                        user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    if host["kind"] != "proxmox":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Cet hôte n'est pas un Proxmox")
    try:
        return await act.guest_action(host, payload.vmid, payload.kind, payload.action,
                                      user["username"], payload.node)
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.post("/hosts/{host_id}/exec")
async def exec_command(host_id: int, payload: CommandIn, user: dict = Depends(current_user)) -> dict:
    host = await _require_host(host_id)
    if host["kind"] not in ("linux", "docker"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Exécution SSH indisponible pour ce type d'hôte")
    try:
        return await act.run_command(host, payload.command, user["username"], payload.timeout)
    except act.ActionError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc


@router.get("/actions")
async def action_history(limit: int = Query(50, le=500), user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        "SELECT a.*, h.name AS host_name FROM action_logs a LEFT JOIN hosts h ON h.id = a.host_id "
        "ORDER BY a.started_at DESC LIMIT :l", {"l": limit}
    )


# ---------------------------------------------------------------- credentials
@router.get("/credentials")
async def list_credentials(user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        "SELECT c.id, c.name, c.kind, c.username, c.created_at, "
        "(SELECT count(*) FROM hosts h WHERE h.credential_id = c.id) AS hosts_count "
        "FROM credentials c ORDER BY c.name"
    )


@router.post("/credentials", status_code=status.HTTP_201_CREATED)
async def create_credential(payload: CredentialIn, user: dict = Depends(current_user)) -> dict:
    from ..vault import encrypt

    if not payload.secret:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Le secret est obligatoire")
    username = None if payload.kind in SECRET_ONLY else payload.username

    existing = await fetch_one("SELECT id FROM credentials WHERE name = :n", {"n": payload.name})
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Un identifiant nommé « {payload.name} » existe déjà")
    cred_id = await execute(
        """INSERT INTO credentials (name, kind, username, secret_enc, passphrase_enc)
           VALUES (:name, :kind, :username, :secret, :pass) RETURNING id""",
        {"name": payload.name, "kind": payload.kind, "username": username,
         "secret": encrypt(payload.secret), "pass": encrypt(payload.passphrase)},
    )
    return {"id": cred_id, "name": payload.name, "kind": payload.kind, "username": username}


@router.patch("/credentials/{cred_id}")
async def update_credential(cred_id: int, payload: CredentialPatch,
                            user: dict = Depends(current_user)) -> dict:
    from ..vault import encrypt

    current = await fetch_one("SELECT * FROM credentials WHERE id = :id", {"id": cred_id})
    if not current:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Identifiant introuvable")

    fields = payload.model_dump(exclude_unset=True)
    kind = fields.get("kind", current["kind"])
    sets, params = [], {"id": cred_id}

    if "name" in fields:
        clash = await fetch_one("SELECT id FROM credentials WHERE name = :n AND id <> :id",
                                {"n": fields["name"], "id": cred_id})
        if clash:
            raise HTTPException(status.HTTP_409_CONFLICT, "Ce nom est déjà pris")
        sets.append("name = :name")
        params["name"] = fields["name"]
    if "kind" in fields:
        sets.append("kind = :kind")
        params["kind"] = kind
    if "username" in fields or "kind" in fields:
        sets.append("username = :username")
        params["username"] = None if kind in SECRET_ONLY else fields.get(
            "username", current["username"]
        )
    # Un champ secret vide signifie « ne pas toucher », pas « effacer ».
    if fields.get("secret"):
        sets.append("secret_enc = :secret")
        params["secret"] = encrypt(fields["secret"])
    if "passphrase" in fields:
        sets.append("passphrase_enc = :pass")
        params["pass"] = encrypt(fields["passphrase"]) if fields["passphrase"] else None

    if not sets:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aucune modification demandée")

    await execute(f"UPDATE credentials SET {', '.join(sets)} WHERE id = :id", params)
    # Les sessions en cache portent l'ancien secret : on les referme.
    for host in await fetch_all("SELECT id FROM hosts WHERE credential_id = :c "
                                "OR bmc_credential_id = :c", {"c": cred_id}):
        pool.drop(host["id"])

    updated = await fetch_one(
        "SELECT id, name, kind, username, created_at FROM credentials WHERE id = :id",
        {"id": cred_id},
    )
    from ..poller import log_event
    await log_event(None, "info", "credentials",
                    f"Identifiant « {updated['name']} » modifié par {user['username']}",
                    {"champs": sorted(fields)})
    return updated


@router.delete("/credentials/{cred_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_credential(cred_id: int, user: dict = Depends(current_user)) -> Response:
    cred = await fetch_one("SELECT name FROM credentials WHERE id = :id", {"id": cred_id})
    await execute("DELETE FROM credentials WHERE id = :id", {"id": cred_id})
    if cred:
        from ..poller import log_event
        await log_event(None, "warning", "credentials",
                        f"Identifiant « {cred['name']} » supprimé par {user['username']}")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------- events
@router.get("/events")
async def list_events(limit: int = Query(200, le=2000), level: str | None = None,
                      source: str | None = None, host_id: int | None = None,
                      search: str | None = None,
                      user: dict = Depends(current_user)) -> dict:
    """Journal filtrable. Le champ `data` porte le détail structuré de l'évènement."""
    clauses, params = [], {"l": limit}
    if level:
        clauses.append("e.level = :lvl")
        params["lvl"] = level
    if source:
        clauses.append("e.source = :src")
        params["src"] = source
    if host_id:
        clauses.append("e.host_id = :hid")
        params["hid"] = host_id
    if search:
        clauses.append("e.message ILIKE :q")
        params["q"] = f"%{search}%"

    where = f" WHERE {' AND '.join(clauses)}" if clauses else ""
    events = await fetch_all(
        "SELECT e.time, e.level, e.source, e.message, e.data, e.host_id, h.name AS host_name "
        f"FROM events e LEFT JOIN hosts h ON h.id = e.host_id{where} "
        "ORDER BY e.time DESC LIMIT :l",
        params,
    )
    sources = await fetch_all(
        "SELECT source, count(*) AS n FROM events "
        "WHERE time > now() - interval '7 days' GROUP BY source ORDER BY n DESC"
    )
    levels = await fetch_all(
        "SELECT level, count(*) AS n FROM events "
        "WHERE time > now() - interval '7 days' GROUP BY level"
    )
    return {
        "events": events,
        "sources": [{"source": s["source"], "count": s["n"]} for s in sources],
        "levels": {l["level"]: l["n"] for l in levels},
    }


@router.get("/alerts")
async def list_alerts(state: str = "firing", user: dict = Depends(current_user)) -> list[dict]:
    return await fetch_all(
        "SELECT a.*, h.name AS host_name, r.name AS rule_name FROM alerts a "
        "LEFT JOIN hosts h ON h.id = a.host_id LEFT JOIN alert_rules r ON r.id = a.rule_id "
        "WHERE a.state = :s ORDER BY a.started_at DESC LIMIT 200", {"s": state}
    )


@router.post("/alerts/{alert_id}/ack")
async def ack_alert(alert_id: int, user: dict = Depends(current_user)) -> dict:
    await execute("UPDATE alerts SET state='acked' WHERE id=:id", {"id": alert_id})
    return {"ok": True}


# -------------------------------------------------------------------- helpers
async def _require_host(host_id: int) -> dict:
    host = await fetch_one("SELECT * FROM hosts WHERE id = :id", {"id": host_id})
    if not host:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Hôte introuvable")
    return host
