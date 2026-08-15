"""Actions sur les systèmes : reboot, upgrade, restart de service/conteneur.

Chaque action est tracée dans action_logs et sa sortie est diffusée en direct
sur le bus (topic « action.<id> ») pour l'affichage temps réel dans l'UI.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import shlex
import time

from .bus import bus
from .collectors import docker as docker_col
from .collectors import proxmox as pve_col
from .collectors import synology as syno_col
from .db import execute, fetch_one
from .poller import log_event, supervisor
from .ssh import SSHError, pool

log = logging.getLogger("mba.actions")

# Commandes de mise à jour par gestionnaire de paquets, détectées à la volée.
UPGRADE_SCRIPT = r"""
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt-get -y autoremove
elif command -v dnf >/dev/null 2>&1; then
  dnf -y upgrade --refresh
elif command -v yum >/dev/null 2>&1; then
  yum -y update
elif command -v pacman >/dev/null 2>&1; then
  pacman -Syu --noconfirm
elif command -v apk >/dev/null 2>&1; then
  apk update && apk upgrade
elif command -v zypper >/dev/null 2>&1; then
  zypper --non-interactive update
else
  echo "Aucun gestionnaire de paquets reconnu"; exit 1
fi
"""

SYSTEM_ACTIONS = {
    "reboot": "systemd-run --on-active=2 --timer-property=AccuracySec=100ms /sbin/reboot || (sleep 2 && reboot) &",
    "shutdown": "systemd-run --on-active=2 --timer-property=AccuracySec=100ms /sbin/poweroff || (sleep 2 && poweroff) &",
}


class ActionError(RuntimeError):
    pass


async def _open_log(host_id: int | None, action: str, target: str | None, username: str) -> int:
    return await execute(
        "INSERT INTO action_logs (host_id, target, action, status, username) "
        "VALUES (:h, :t, :a, 'running', :u) RETURNING id",
        {"h": host_id, "t": target, "a": action, "u": username},
    )


async def _close_log(log_id: int, status: str, output: str) -> None:
    await execute(
        "UPDATE action_logs SET status=:s, output=:o, ended_at=now() WHERE id=:id",
        {"s": status, "o": output[-20000:], "id": log_id},
    )
    bus.publish(f"action.{log_id}", {"id": log_id, "status": status, "done": True})


def _emit(log_id: int, chunk: str) -> None:
    bus.publish(f"action.{log_id}", {"id": log_id, "chunk": chunk})


# --------------------------------------------------------------------- Linux
async def run_ssh_stream(host: dict, command: str, log_id: int, timeout: float = 1800) -> tuple[int, str]:
    """Exécute une commande SSH en diffusant sa sortie ligne par ligne."""
    conn = await pool.get(host)
    buffer: list[str] = []
    async with conn.create_process(command) as proc:
        async def pump(stream) -> None:
            async for line in stream:
                buffer.append(line)
                _emit(log_id, line)

        tasks = [asyncio.create_task(pump(proc.stdout)), asyncio.create_task(pump(proc.stderr))]
        try:
            await asyncio.wait_for(asyncio.gather(*tasks), timeout=timeout)
            result = await proc.wait()
        except asyncio.TimeoutError:
            for t in tasks:
                t.cancel()
            proc.terminate()
            raise ActionError(f"Timeout après {timeout:.0f}s") from None
    return result.exit_status or 0, "".join(buffer)


async def upgrade_host(host: dict, username: str) -> dict:
    log_id = await _open_log(host["id"], "upgrade", None, username)
    _emit(log_id, f"→ Mise à jour de {host['name']} ({host['address']})\n")
    try:
        code, output = await run_ssh_stream(host, UPGRADE_SCRIPT, log_id, timeout=3600)
    except (SSHError, ActionError) as exc:
        await _close_log(log_id, "failed", str(exc))
        await log_event(host["id"], "critical", "action", f"Mise à jour de {host['name']} échouée : {exc}")
        raise ActionError(str(exc)) from exc

    status = "success" if code == 0 else "failed"
    await _close_log(log_id, status, output)
    await log_event(host["id"], "info" if code == 0 else "warning", "action",
                    f"Mise à jour de {host['name']} : {status}")
    # On rafraîchit tout de suite le compteur d'updates disponibles.
    asyncio.create_task(_refresh_meta_later(host["id"]))
    return {"log_id": log_id, "status": status, "exit_code": code}


async def _refresh_meta_later(host_id: int, delay: float = 5.0) -> None:
    await asyncio.sleep(delay)
    worker = supervisor.workers.get(host_id)
    if worker:
        worker.last_slow = 0


async def power_action(host: dict, action: str, username: str) -> dict:
    if action not in SYSTEM_ACTIONS:
        raise ActionError(f"Action inconnue : {action}")
    log_id = await _open_log(host["id"], action, None, username)
    _emit(log_id, f"→ {action} de {host['name']}\n")
    try:
        # La commande est détachée : la connexion tombe, c'est attendu.
        with contextlib.suppress(SSHError, asyncio.TimeoutError):
            await pool.run(host, SYSTEM_ACTIONS[action], timeout=8)
    finally:
        pool.drop(host["id"])
    await _close_log(log_id, "success", f"{action} demandé")
    await log_event(host["id"], "warning", "action", f"{action.capitalize()} demandé sur {host['name']} par {username}")
    await execute("UPDATE hosts SET status='unknown' WHERE id=:id", {"id": host["id"]})
    return {"log_id": log_id, "status": "success"}


async def service_action(host: dict, service: str, action: str, username: str) -> dict:
    if action not in ("restart", "start", "stop", "reload", "status"):
        raise ActionError(f"Action service inconnue : {action}")
    safe = shlex.quote(service)
    log_id = await _open_log(host["id"], f"systemctl {action}", service, username)
    try:
        code, out, err = await pool.run_status(host, f"systemctl {action} {safe} 2>&1; systemctl is-active {safe}", 60)
    except SSHError as exc:
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    output = out + err
    _emit(log_id, output)
    status = "success" if code == 0 else "failed"
    await _close_log(log_id, status, output)
    await log_event(host["id"], "info", "action", f"{action} {service} sur {host['name']} → {status}")
    return {"log_id": log_id, "status": status, "output": output.strip()}


# -------------------------------------------------------------------- Docker
async def container_action(host: dict, ext_id: str, action: str, username: str) -> dict:
    log_id = await _open_log(host["id"], f"docker {action}", ext_id, username)
    try:
        output = await docker_col.container_action(host, ext_id, action)
    except Exception as exc:  # noqa: BLE001
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    await _close_log(log_id, "success", output)
    await log_event(host["id"], "info", "action", f"Conteneur {ext_id} : {action} sur {host['name']}")
    asyncio.create_task(_refresh_containers_later(host["id"]))
    return {"log_id": log_id, "status": "success", "output": output}


async def _refresh_containers_later(host_id: int, delay: float = 2.0) -> None:
    await asyncio.sleep(delay)
    worker = supervisor.workers.get(host_id)
    if worker:
        worker.last_containers = 0


# ------------------------------------------------------------------ Proxmox
async def guest_action(host: dict, vmid: int, kind: str, action: str, username: str, node: str | None = None) -> dict:
    log_id = await _open_log(host["id"], f"pve {action}", f"{kind}/{vmid}", username)
    client = await pve_col.client_for_host(host)
    try:
        if not node:
            row = await fetch_one(
                "SELECT stats FROM containers WHERE host_id=:h AND ext_id=:e",
                {"h": host["id"], "e": f"{kind}/{vmid}"},
            )
            node = ((row or {}).get("stats") or {}).get("node")
        if not node:
            nodes = await client.get("/nodes") or []
            node = nodes[0]["node"] if nodes else None
        if not node:
            raise ActionError("Nœud Proxmox introuvable")
        task = await client.guest_action(node, kind, vmid, action)
    except Exception as exc:  # noqa: BLE001
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    finally:
        await client.close()
    await _close_log(log_id, "success", f"Tâche PVE {task}")
    await log_event(host["id"], "info", "action", f"{kind} {vmid} : {action} sur {node}")
    asyncio.create_task(_refresh_containers_later(host["id"]))
    return {"log_id": log_id, "status": "success", "task": task}


async def pve_node_action(host: dict, node: str, action: str, username: str) -> dict:
    log_id = await _open_log(host["id"], f"pve node {action}", node, username)
    client = await pve_col.client_for_host(host)
    try:
        await client.node_action(node, action)
    except Exception as exc:  # noqa: BLE001
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    finally:
        await client.close()
    await _close_log(log_id, "success", f"{action} demandé sur {node}")
    await log_event(host["id"], "warning", "action", f"{action} du nœud Proxmox {node} par {username}")
    return {"log_id": log_id, "status": "success"}


# ----------------------------------------------------------------- Synology
async def syno_action(host: dict, action: str, username: str, package_id: str | None = None) -> dict:
    log_id = await _open_log(host["id"], f"dsm {action}", package_id, username)
    client = await syno_col.client_for_host(host)
    try:
        if action in ("reboot", "shutdown"):
            await client.system_action(action)
            output = f"{action} DSM demandé"
        elif action in ("start", "stop") and package_id:
            await client.package_action(package_id, action)
            output = f"Paquet {package_id} : {action}"
        else:
            raise ActionError(f"Action DSM inconnue : {action}")
    except Exception as exc:  # noqa: BLE001
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    finally:
        await client.logout()
    await _close_log(log_id, "success", output)
    await log_event(host["id"], "warning" if action in ("reboot", "shutdown") else "info",
                    "action", f"{output} sur {host['name']} par {username}")
    return {"log_id": log_id, "status": "success", "output": output}


# ------------------------------------------------------------ commande libre
async def run_command(host: dict, command: str, username: str, timeout: float = 120) -> dict:
    log_id = await _open_log(host["id"], "exec", command[:120], username)
    started = time.time()
    try:
        code, output = await run_ssh_stream(host, command, log_id, timeout=timeout)
    except (SSHError, ActionError) as exc:
        await _close_log(log_id, "failed", str(exc))
        raise ActionError(str(exc)) from exc
    status = "success" if code == 0 else "failed"
    await _close_log(log_id, status, output)
    await log_event(host["id"], "info", "action", f"Commande sur {host['name']} : {command[:80]}")
    return {"log_id": log_id, "status": status, "exit_code": code,
            "output": output, "duration": round(time.time() - started, 2)}
