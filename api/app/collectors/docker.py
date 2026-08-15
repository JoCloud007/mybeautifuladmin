"""Collecteur Docker : via socket local ou via SSH sur un hôte distant."""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
from typing import Any

import httpx

from ..ssh import SSHError, pool

log = logging.getLogger("mba.docker")

DOCKER_SOCK = "/var/run/docker.sock"

# Labels posés par docker compose : ils portent le regroupement par projet.
COMPOSE_PROJECT = "com.docker.compose.project"
COMPOSE_SERVICE = "com.docker.compose.service"
COMPOSE_WORKDIR = "com.docker.compose.project.working_dir"

PS_FMT = "{{json .}}"
LIST_CMD = f"docker ps -a --no-trunc --format '{PS_FMT}'"
STATS_CMD = "docker stats --no-stream --format '{{json .}}'"


# ------------------------------------------------------------------ socket local
def socket_available() -> bool:
    return os.path.exists(DOCKER_SOCK)


def _local_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.AsyncHTTPTransport(uds=DOCKER_SOCK),
        base_url="http://docker",
        timeout=20.0,
    )


async def local_containers() -> list[dict]:
    async with _local_client() as client:
        resp = await client.get("/v1.43/containers/json", params={"all": "1"})
        resp.raise_for_status()
        raw = resp.json()

        async def stats(cid: str) -> dict:
            try:
                r = await client.get(f"/v1.43/containers/{cid}/stats", params={"stream": "false", "one-shot": "true"})
                return r.json()
            except (httpx.HTTPError, ValueError):
                return {}

        running = [c for c in raw if c.get("State") == "running"]
        results = await asyncio.gather(*(stats(c["Id"]) for c in running), return_exceptions=True)
        by_id = {c["Id"]: (s if isinstance(s, dict) else {}) for c, s in zip(running, results)}

    containers = []
    for c in raw:
        st = by_id.get(c["Id"], {})
        labels = c.get("Labels") or {}
        containers.append({
            "ext_id": c["Id"][:12],
            "name": (c.get("Names") or ["?"])[0].lstrip("/"),
            "image": c.get("Image", ""),
            "state": c.get("State", ""),
            "status": c.get("Status", ""),
            "kind": "docker",
            "ports": [
                {"private": p.get("PrivatePort"), "public": p.get("PublicPort"), "type": p.get("Type")}
                for p in (c.get("Ports") or []) if p.get("PublicPort")
            ],
            "stats": _stats_from_api(st),
            "labels": labels,
            "project": labels.get(COMPOSE_PROJECT),
            "service": labels.get(COMPOSE_SERVICE),
            "created": c.get("Created"),
        })
    return containers


def _stats_from_api(st: dict) -> dict:
    if not st:
        return {}
    try:
        cpu = st["cpu_stats"]
        pre = st["precpu_stats"]
        cpu_delta = cpu["cpu_usage"]["total_usage"] - pre["cpu_usage"].get("total_usage", 0)
        sys_delta = cpu.get("system_cpu_usage", 0) - pre.get("system_cpu_usage", 0)
        ncpu = cpu.get("online_cpus") or len(cpu["cpu_usage"].get("percpu_usage") or [1])
        cpu_pct = (cpu_delta / sys_delta) * ncpu * 100.0 if sys_delta > 0 else 0.0
    except (KeyError, TypeError, ZeroDivisionError):
        cpu_pct = 0.0
    mem = st.get("memory_stats", {})
    usage = mem.get("usage", 0) - (mem.get("stats", {}) or {}).get("inactive_file", 0)
    limit = mem.get("limit", 0)
    nets = st.get("networks") or {}
    return {
        "cpu": round(cpu_pct, 2),
        "mem": usage,
        "mem_limit": limit,
        "mem_percent": round(100.0 * usage / limit, 2) if limit else 0.0,
        "net_rx": sum(n.get("rx_bytes", 0) for n in nets.values()),
        "net_tx": sum(n.get("tx_bytes", 0) for n in nets.values()),
    }


# --------------------------------------------------------------------- via SSH
def _parse_size(text: str) -> float:
    """« 1.234GiB » → octets."""
    text = (text or "").strip()
    units = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
             "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4}
    number = ""
    for char in text:
        if char.isdigit() or char in ".-":
            number += char
        else:
            break
    unit = text[len(number):].strip().upper() or "B"
    try:
        return float(number) * units.get(unit, 1)
    except ValueError:
        return 0.0


async def remote_containers(host: dict) -> list[dict]:
    try:
        listing = await pool.run(host, LIST_CMD, timeout=20)
    except SSHError as exc:
        raise SSHError(f"docker ps: {exc}") from exc

    containers = []
    for line in listing.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            c = json.loads(line)
        except json.JSONDecodeError:
            continue
        ports = []
        for chunk in (c.get("Ports") or "").split(","):
            chunk = chunk.strip()
            if "->" in chunk:
                public, _, private = chunk.partition("->")
                ports.append({
                    "public": public.rsplit(":", 1)[-1],
                    "private": private.split("/")[0],
                    "type": private.split("/")[-1] if "/" in private else "tcp",
                })
        # `docker ps` sérialise les labels en « k=v,k=v ».
        labels = {}
        for pair in (c.get("Labels") or "").split(","):
            key, sep, value = pair.partition("=")
            if sep:
                labels[key.strip()] = value.strip()
        containers.append({
            "ext_id": (c.get("ID") or "")[:12],
            "name": c.get("Names", ""),
            "image": c.get("Image", ""),
            "state": c.get("State", ""),
            "status": c.get("Status", ""),
            "kind": "docker",
            "ports": ports,
            "stats": {},
            "labels": labels,
            "project": labels.get(COMPOSE_PROJECT),
            "service": labels.get(COMPOSE_SERVICE),
        })

    # Les stats coûtent ~1 s : on ne les demande que s'il y a des conteneurs actifs.
    if any(c["state"] == "running" for c in containers):
        try:
            raw_stats = await pool.run(host, STATS_CMD, timeout=30)
            by_name = {}
            for line in raw_stats.splitlines():
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    s = json.loads(line)
                except json.JSONDecodeError:
                    continue
                mem_usage, _, mem_limit = (s.get("MemUsage") or "").partition("/")
                net_rx, _, net_tx = (s.get("NetIO") or "").partition("/")
                by_name[s.get("Name", "")] = {
                    "cpu": float((s.get("CPUPerc") or "0%").rstrip("%") or 0),
                    "mem": _parse_size(mem_usage),
                    "mem_limit": _parse_size(mem_limit),
                    "mem_percent": float((s.get("MemPerc") or "0%").rstrip("%") or 0),
                    "net_rx": _parse_size(net_rx),
                    "net_tx": _parse_size(net_tx),
                }
            for c in containers:
                c["stats"] = by_name.get(c["name"], {})
        except SSHError as exc:
            log.debug("docker stats indisponible sur %s: %s", host["name"], exc)

    return containers


async def collect(host: dict) -> list[dict]:
    if host.get("address") in ("local", "127.0.0.1", "localhost") and socket_available():
        return await local_containers()
    return await remote_containers(host)


# --------------------------------------------------------------------- actions
ACTIONS = {"start", "stop", "restart", "pause", "unpause", "kill"}


async def container_action(host: dict, ext_id: str, action: str) -> str:
    if action not in ACTIONS:
        raise ValueError(f"Action conteneur inconnue: {action}")
    if host.get("address") in ("local", "127.0.0.1", "localhost") and socket_available():
        async with _local_client() as client:
            resp = await client.post(f"/v1.43/containers/{ext_id}/{action}")
            if resp.status_code >= 400:
                raise RuntimeError(resp.text[:300])
            return f"{action} ok"
    code, out, err = await pool.run_status(host, f"docker {action} {ext_id}", timeout=60)
    if code != 0:
        raise RuntimeError(err.strip() or out.strip())
    return out.strip() or f"{action} ok"


async def container_logs(host: dict, ext_id: str, lines: int = 200) -> str:
    if host.get("address") in ("local", "127.0.0.1", "localhost") and socket_available():
        async with _local_client() as client:
            resp = await client.get(
                f"/v1.43/containers/{ext_id}/logs",
                params={"stdout": "true", "stderr": "true", "tail": str(lines)},
            )
            # Le flux Docker est multiplexé : 8 octets d'en-tête par trame.
            data, out = resp.content, []
            i = 0
            while i + 8 <= len(data):
                size = int.from_bytes(data[i + 4:i + 8], "big")
                out.append(data[i + 8:i + 8 + size].decode("utf-8", "replace"))
                i += 8 + size
            return "".join(out) or data.decode("utf-8", "replace")
    _, out, err = await pool.run_status(host, f"docker logs --tail {int(lines)} {ext_id} 2>&1", timeout=30)
    return out or err


# ------------------------------------------------------------ ménage / purge
# Chaque cible : (endpoint API, commande CLI, libellé).
PRUNE_TARGETS: dict[str, tuple[str, str, str]] = {
    "containers": ("/v1.43/containers/prune", "docker container prune -f", "Conteneurs arrêtés"),
    "images": ("/v1.43/images/prune", "docker image prune -f", "Images inutilisées (dangling)"),
    "images_all": ("/v1.43/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D",
                   "docker image prune -af", "Toutes les images non utilisées"),
    "volumes": ("/v1.43/volumes/prune", "docker volume prune -f", "Volumes orphelins"),
    "networks": ("/v1.43/networks/prune", "docker network prune -f", "Réseaux inutilisés"),
    "build_cache": ("/v1.43/build/prune", "docker builder prune -f", "Cache de construction"),
}


def _is_local(host: dict) -> bool:
    return host.get("address") in ("local", "127.0.0.1", "localhost") and socket_available()


async def disk_usage(host: dict) -> dict[str, Any]:
    """Équivalent de « docker system df » : ce qui est utilisé et récupérable."""
    if _is_local(host):
        async with _local_client() as client:
            resp = await client.get("/v1.43/system/df")
            resp.raise_for_status()
            data = resp.json()

        images = data.get("Images") or []
        containers = data.get("Containers") or []
        volumes = data.get("Volumes") or []
        cache = data.get("BuildCache") or []
        return {
            "images": {
                "count": len(images),
                "size": sum(i.get("Size", 0) for i in images),
                "reclaimable": sum(i.get("Size", 0) for i in images if not i.get("Containers")),
            },
            "containers": {
                "count": len(containers),
                "size": sum(c.get("SizeRw", 0) for c in containers),
                "reclaimable": sum(c.get("SizeRw", 0) for c in containers
                                   if c.get("State") not in ("running", "paused")),
            },
            "volumes": {
                "count": len(volumes),
                "size": sum((v.get("UsageData") or {}).get("Size", 0) or 0 for v in volumes),
                "reclaimable": sum((v.get("UsageData") or {}).get("Size", 0) or 0 for v in volumes
                                   if ((v.get("UsageData") or {}).get("RefCount") or 0) == 0),
            },
            "build_cache": {
                "count": len(cache),
                "size": sum(c.get("Size", 0) for c in cache),
                "reclaimable": sum(c.get("Size", 0) for c in cache if not c.get("InUse")),
            },
        }

    # En SSH on lit la sortie tabulée de `docker system df`.
    raw = await pool.run(host, "docker system df --format '{{json .}}'", timeout=30)
    out: dict[str, Any] = {}
    mapping = {"Images": "images", "Containers": "containers",
               "Local Volumes": "volumes", "Build Cache": "build_cache"}
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        key = mapping.get(row.get("Type", ""))
        if not key:
            continue
        out[key] = {
            "count": int(row.get("TotalCount") or 0),
            "size": _parse_size(row.get("Size", "0")),
            "reclaimable": _parse_size((row.get("Reclaimable") or "0").split("(")[0]),
        }
    return out


async def prune(host: dict, target: str) -> dict[str, Any]:
    """Purge une catégorie de ressources et renvoie l'espace récupéré."""
    if target not in PRUNE_TARGETS:
        raise ValueError(f"Cible de purge inconnue : {target}")
    endpoint, command, label = PRUNE_TARGETS[target]

    if _is_local(host):
        async with _local_client() as client:
            resp = await client.post(endpoint, timeout=180.0)
            if resp.status_code >= 400:
                raise RuntimeError(resp.text[:300])
            data = resp.json()
        deleted = (data.get("ContainersDeleted") or data.get("ImagesDeleted")
                   or data.get("VolumesDeleted") or data.get("NetworksDeleted") or [])
        return {
            "target": target,
            "label": label,
            "reclaimed": data.get("SpaceReclaimed", 0),
            "removed": len(deleted) if isinstance(deleted, list) else 0,
        }

    code, out, err = await pool.run_status(host, command, timeout=300)
    if code != 0:
        raise RuntimeError(err.strip() or out.strip())
    reclaimed = 0.0
    for line in out.splitlines():
        if "reclaimed space" in line.lower():
            reclaimed = _parse_size(line.split(":")[-1])
    return {"target": target, "label": label, "reclaimed": reclaimed,
            "removed": len([l for l in out.splitlines() if l.strip() and ":" not in l]),
            "output": out.strip()[:2000]}


# ------------------------------------------------------------- mise à jour
async def pull_image(host: dict, image: str) -> dict[str, Any]:
    """Récupère la dernière version d'une image et dit si elle a changé."""
    if not image:
        raise ValueError("Image inconnue pour ce conteneur")

    if _is_local(host):
        async with _local_client() as client:
            before = await client.get(f"/v1.43/images/{image}/json")
            before_id = before.json().get("Id") if before.status_code == 200 else None
            name, _, tag = image.rpartition(":")
            resp = await client.post(
                "/v1.43/images/create",
                params={"fromImage": name or image, "tag": tag or "latest"},
                timeout=600.0,
            )
            if resp.status_code >= 400:
                raise RuntimeError(resp.text[:300])
            after = await client.get(f"/v1.43/images/{image}/json")
            after_id = after.json().get("Id") if after.status_code == 200 else None
        updated = bool(before_id and after_id and before_id != after_id)
        return {"image": image, "updated": updated,
                "detail": "Nouvelle image récupérée" if updated else "Déjà à jour"}

    code, out, err = await pool.run_status(host, f"docker pull {shlex.quote(image)}", timeout=900)
    if code != 0:
        raise RuntimeError((err or out).strip()[:300])
    updated = "Downloaded newer image" in out or "Pull complete" in out
    return {
        "image": image,
        "updated": updated,
        "detail": "Nouvelle image récupérée" if updated else "Déjà à jour",
        "output": out.strip()[:2000],
    }


async def compose_update(host: dict, project: str, working_dir: str) -> dict[str, Any]:
    """`docker compose pull` puis `up -d` sur une pile, dans son répertoire.

    C'est la seule façon sûre de recréer des conteneurs : compose connaît leur
    configuration complète, ce que `docker run` ne permet pas de reconstituer.
    """
    if not working_dir:
        raise RuntimeError(
            "Répertoire du projet inconnu — la pile n'a pas été démarrée par docker compose, "
            "ou le label com.docker.compose.project.working_dir est absent."
        )
    quoted_dir = shlex.quote(working_dir)
    quoted_project = shlex.quote(project)
    command = (
        f"cd {quoted_dir} && "
        f"docker compose -p {quoted_project} pull && "
        f"docker compose -p {quoted_project} up -d --remove-orphans"
    )
    code, out, err = await pool.run_status(host, command, timeout=1800)
    output = (out + err).strip()
    if code != 0:
        raise RuntimeError(output[-800:] or f"échec (code {code})")
    return {
        "project": project,
        "updated": "Pulling" in output or "Recreating" in output or "Started" in output,
        "output": output[-4000:],
    }


async def collect_stats_metrics(containers: list[dict]) -> dict[str, Any]:
    running = [c for c in containers if c.get("state") == "running"]
    return {
        "docker.containers.total": float(len(containers)),
        "docker.containers.running": float(len(running)),
        "docker.cpu.total": round(sum((c.get("stats") or {}).get("cpu", 0) for c in running), 2),
        "docker.mem.total": sum((c.get("stats") or {}).get("mem", 0) for c in running),
    }
