"""Scan réseau et empreinte des équipements.

Balayage TCP asynchrone (pas de raw socket, donc pas de privilège particulier
dans le conteneur), puis empreinte HTTP pour distinguer un Proxmox d'un DSM,
d'un Ollama ou d'un simple service web.
"""
from __future__ import annotations

import asyncio
import contextlib
import ipaddress
import logging
import socket
import ssl
from dataclasses import dataclass, field
from typing import Any

import httpx

log = logging.getLogger("mba.discovery")

# Ports sondés, du plus discriminant au plus générique.
FINGERPRINTS: dict[int, str] = {
    8006: "proxmox",
    5001: "synology",
    5000: "synology",
    11434: "ollama",
    22: "linux",
    2375: "docker",
    2376: "docker",
    9090: "cockpit",
    443: "https",
    80: "http",
    8080: "http-alt",
    3000: "http-alt",
    8443: "https-alt",
    445: "smb",
    548: "afp",
    3306: "mysql",
    5432: "postgres",
    6379: "redis",
    1883: "mqtt",
    32400: "plex",
    8123: "homeassistant",
}
SCAN_PORTS = list(FINGERPRINTS)

KIND_PRIORITY = ["proxmox", "synology", "ollama", "docker", "linux", "generic"]


@dataclass(slots=True)
class Candidate:
    address: str
    hostname: str | None = None
    open_ports: list[int] = field(default_factory=list)
    guessed_kind: str = "generic"
    evidence: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict:
        return {
            "address": self.address,
            "hostname": self.hostname,
            "open_ports": sorted(self.open_ports),
            "guessed_kind": self.guessed_kind,
            "evidence": self.evidence,
        }


async def probe_port(address: str, port: int, timeout: float = 0.8) -> bool:
    try:
        fut = asyncio.open_connection(address, port)
        reader, writer = await asyncio.wait_for(fut, timeout=timeout)
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()
    return True


async def reverse_dns(address: str) -> str | None:
    loop = asyncio.get_running_loop()
    try:
        name, _, _ = await asyncio.wait_for(
            loop.run_in_executor(None, socket.gethostbyaddr, address), timeout=1.5
        )
        return name
    except (OSError, asyncio.TimeoutError):
        return None


async def ssh_banner(address: str, port: int = 22) -> str | None:
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(address, port), timeout=1.5)
        banner = await asyncio.wait_for(reader.readline(), timeout=1.5)
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        return banner.decode("utf-8", "replace").strip() or None
    except (OSError, asyncio.TimeoutError):
        return None


async def http_fingerprint(address: str, port: int, secure: bool) -> dict[str, Any]:
    scheme = "https" if secure else "http"
    url = f"{scheme}://{address}:{port}/"
    out: dict[str, Any] = {}
    try:
        async with httpx.AsyncClient(verify=False, timeout=4.0, follow_redirects=True) as client:
            resp = await client.get(url)
            body = resp.text[:4000].lower()
            out["status"] = resp.status_code
            out["server"] = resp.headers.get("server")
            title = ""
            if "<title>" in body:
                title = body.split("<title>", 1)[1].split("</title>", 1)[0].strip()[:120]
            out["title"] = title
            if "proxmox" in body or "pve" in (out.get("server") or "").lower():
                out["product"] = "proxmox"
            elif "synology" in body or "syno" in body or "diskstation" in body:
                out["product"] = "synology"
            elif "ollama is running" in body:
                out["product"] = "ollama"
    except httpx.HTTPError as exc:
        out["error"] = type(exc).__name__
    return out


async def tls_subject(address: str, port: int) -> str | None:
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(address, port, ssl=ctx), timeout=3.0
        )
        cert = writer.get_extra_info("peercert")
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()
        if cert:
            subject = dict(x[0] for x in cert.get("subject", ()))
            return subject.get("commonName")
    except (OSError, asyncio.TimeoutError, ssl.SSLError):
        return None
    return None


async def scan_host(address: str, ports: list[int], sem: asyncio.Semaphore) -> Candidate | None:
    async with sem:
        results = await asyncio.gather(*(probe_port(address, p) for p in ports))
    open_ports = [p for p, ok in zip(ports, results) if ok]
    if not open_ports:
        return None

    cand = Candidate(address=address, open_ports=open_ports)
    cand.hostname = await reverse_dns(address)

    # Empreintes ciblées selon les ports ouverts.
    tasks = {}
    if 22 in open_ports:
        tasks["ssh"] = ssh_banner(address)
    if 8006 in open_ports:
        tasks["proxmox"] = http_fingerprint(address, 8006, True)
    if 5001 in open_ports:
        tasks["dsm"] = http_fingerprint(address, 5001, True)
    elif 5000 in open_ports:
        tasks["dsm"] = http_fingerprint(address, 5000, False)
    if 11434 in open_ports:
        tasks["ollama"] = http_fingerprint(address, 11434, False)
    if 443 in open_ports:
        tasks["https"] = http_fingerprint(address, 443, True)
    elif 80 in open_ports:
        tasks["http"] = http_fingerprint(address, 80, False)

    if tasks:
        values = await asyncio.gather(*tasks.values(), return_exceptions=True)
        for key, value in zip(tasks, values):
            if not isinstance(value, Exception) and value:
                cand.evidence[key] = value

    cand.guessed_kind = _guess(cand)
    return cand


def _guess(cand: Candidate) -> str:
    ev = cand.evidence
    if ev.get("proxmox", {}).get("product") == "proxmox" or 8006 in cand.open_ports:
        return "proxmox"
    if ev.get("dsm", {}).get("product") == "synology" or {5000, 5001} & set(cand.open_ports):
        return "synology"
    banner = (ev.get("ssh") or "").lower()
    if "synology" in banner:
        return "synology"
    if ev.get("ollama", {}).get("product") == "ollama":
        return "ollama"
    if 22 in cand.open_ports:
        return "linux"
    if {2375, 2376} & set(cand.open_ports):
        return "docker"
    return "generic"


def expand_targets(spec: str) -> list[str]:
    """« 192.168.1.0/24, 10.0.0.5, 10.0.0.10-10.0.0.20 » → liste d'IP."""
    targets: list[str] = []
    for chunk in spec.replace(";", ",").split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            if "-" in chunk:
                start, _, end = chunk.partition("-")
                a = ipaddress.ip_address(start.strip())
                b = ipaddress.ip_address(end.strip())
                current = a
                while current <= b and len(targets) < 8192:
                    targets.append(str(current))
                    current += 1
            elif "/" in chunk:
                net = ipaddress.ip_network(chunk, strict=False)
                if net.num_addresses > 8192:
                    raise ValueError(f"Plage trop large: {chunk}")
                targets.extend(str(ip) for ip in net.hosts())
            else:
                targets.append(str(ipaddress.ip_address(chunk)))
        except ValueError as exc:
            raise ValueError(f"Cible invalide « {chunk} »: {exc}") from exc
    return targets


async def scan(spec: str, ports: list[int] | None = None, concurrency: int = 256,
               progress=None) -> list[Candidate]:
    targets = expand_targets(spec)
    ports = ports or SCAN_PORTS
    sem = asyncio.Semaphore(concurrency)
    found: list[Candidate] = []
    done = 0

    async def run(address: str) -> None:
        nonlocal done
        try:
            cand = await scan_host(address, ports, sem)
            if cand:
                found.append(cand)
                if progress:
                    await progress({"type": "found", "host": cand.as_dict()})
        finally:
            done += 1
            if progress and done % 8 == 0:
                await progress({"type": "progress", "done": done, "total": len(targets)})

    await asyncio.gather(*(run(t) for t in targets))
    if progress:
        await progress({"type": "progress", "done": len(targets), "total": len(targets)})
    found.sort(key=lambda c: ipaddress.ip_address(c.address))
    return found
