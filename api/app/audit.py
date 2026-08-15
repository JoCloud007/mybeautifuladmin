"""Analyse de posture : obsolescence, correctifs manquants, durcissement.

Les contrôles s'appuient sur ce que les collecteurs remontent déjà (paquets en
attente, configuration sshd, pare-feu, ports en écoute, SMART, certificats) —
aucun scan intrusif n'est lancé. Chaque constat porte un code stable, ce qui
permet de suivre son cycle de vie : apparu, toujours présent, résolu.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import re
import ssl
from dataclasses import dataclass, field
from typing import Any

from .bus import bus
from .db import execute, execute_many, fetch_all

log = logging.getLogger("mba.audit")

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
SEVERITY_WEIGHT = {"critical": 40, "high": 20, "medium": 8, "low": 3, "info": 0}

# Fins de support des distributions courantes (AAAA-MM-JJ).
# Sert à signaler qu'une machine ne recevra plus de correctifs de sécurité.
EOL: dict[str, dict[str, str]] = {
    "debian": {"9": "2022-06-30", "10": "2024-06-30", "11": "2026-08-31", "12": "2028-06-30",
               "13": "2030-06-30"},
    "ubuntu": {"16.04": "2021-04-30", "18.04": "2023-05-31", "20.04": "2025-05-31",
               "22.04": "2027-06-01", "24.04": "2029-05-31", "24.10": "2025-07-11",
               "25.04": "2026-01-15"},
    "centos": {"7": "2024-06-30", "8": "2021-12-31"},
    "fedora": {"38": "2024-05-21", "39": "2024-11-12", "40": "2025-05-13", "41": "2025-11-19"},
    "alpine": {"3.16": "2024-05-23", "3.17": "2024-11-22", "3.18": "2025-05-09",
               "3.19": "2025-11-01", "3.20": "2026-04-01"},
}

# Ports qu'on ne veut pas voir ouverts sans raison, avec le risque associé.
RISKY_PORTS: dict[int, tuple[str, str, str]] = {
    23: ("high", "Telnet", "Protocole en clair : mots de passe interceptables. Utilise SSH."),
    21: ("medium", "FTP", "Transfert en clair. Préfère SFTP ou FTPS."),
    2375: ("critical", "API Docker non chiffrée",
           "Un accès à ce port donne le contrôle root de l'hôte. Ferme-le ou active TLS (2376)."),
    3306: ("medium", "MySQL/MariaDB exposé",
           "Restreins l'écoute à 127.0.0.1 ou filtre par pare-feu."),
    5432: ("medium", "PostgreSQL exposé",
           "Restreins l'écoute à 127.0.0.1 ou filtre par pare-feu."),
    6379: ("high", "Redis exposé",
           "Redis sans mot de passe donne souvent une exécution de code. Lie-le à 127.0.0.1."),
    27017: ("high", "MongoDB exposé", "Restreins l'écoute et active l'authentification."),
    9200: ("high", "Elasticsearch exposé", "Restreins l'écoute et active la sécurité."),
    5900: ("medium", "VNC exposé", "Passe par un tunnel SSH ou un VPN."),
    3389: ("medium", "RDP exposé", "Filtre par pare-feu ou passe par VPN."),
    445: ("low", "Partage SMB", "Vérifie que SMBv1 est désactivé."),
    11211: ("high", "Memcached exposé", "Amplification DDoS possible. Lie-le à 127.0.0.1."),
}


@dataclass(slots=True)
class Finding:
    code: str
    severity: str
    title: str
    detail: str = ""
    remediation: str = ""
    host_id: int | None = None
    service_id: int | None = None
    data: dict[str, Any] = field(default_factory=dict)


# --------------------------------------------------------------- contrôles
def check_host(host: dict) -> list[Finding]:
    meta = host.get("meta") or {}
    findings: list[Finding] = []
    hid = host["id"]

    # --- correctifs -----------------------------------------------------
    security_updates = int(meta.get("security_updates") or 0)
    updates = int(meta.get("updates") or 0)
    if security_updates > 0:
        findings.append(Finding(
            code="patch.security", severity="high", host_id=hid,
            title=f"{security_updates} correctif(s) de sécurité en attente",
            detail=f"{updates} paquet(s) à mettre à jour au total.",
            remediation="Lance la mise à jour depuis la fiche de l'hôte, ou planifie-la.",
            data={"updates": updates, "security": security_updates},
        ))
    elif updates >= 30:
        findings.append(Finding(
            code="patch.pending", severity="medium", host_id=hid,
            title=f"{updates} paquets en retard",
            detail="Un parc à jour limite la surface d'attaque et les régressions.",
            remediation="Programme une mise à jour récurrente dans le Planificateur.",
            data={"updates": updates},
        ))
    elif updates > 0:
        findings.append(Finding(
            code="patch.pending", severity="low", host_id=hid,
            title=f"{updates} paquet(s) à mettre à jour",
            remediation="Mise à jour depuis la fiche de l'hôte.",
            data={"updates": updates},
        ))

    if meta.get("reboot_required"):
        findings.append(Finding(
            code="patch.reboot", severity="medium", host_id=hid,
            title="Redémarrage requis",
            detail="Des correctifs installés ne sont pas encore actifs.",
            remediation="Redémarre la machine pendant une fenêtre de maintenance.",
        ))

    running, installed = meta.get("kernel_running"), meta.get("kernel_installed")
    if running and installed and running != installed:
        findings.append(Finding(
            code="patch.kernel", severity="high", host_id=hid,
            title="Noyau plus récent installé mais non chargé",
            detail=f"En cours : {running} · installé : {installed}",
            remediation="Redémarre pour activer le nouveau noyau.",
            data={"running": running, "installed": installed},
        ))

    if meta.get("os") and not meta.get("auto_updates") and host["kind"] in ("linux", "docker"):
        findings.append(Finding(
            code="patch.unattended", severity="low", host_id=hid,
            title="Mises à jour automatiques désactivées",
            remediation="Installe unattended-upgrades, ou couvre l'hôte par une planification MBA.",
        ))

    # --- fin de support --------------------------------------------------
    eol = _eol_status(meta.get("os") or "")
    if eol:
        expired, name, date = eol
        findings.append(Finding(
            code="os.eol", severity="critical" if expired else "medium", host_id=hid,
            title=("Système en fin de support" if expired else "Fin de support proche"),
            detail=f"{name} — support {'terminé' if expired else 'jusqu’au'} {date}.",
            remediation="Planifie une montée de version : sans support, plus aucun correctif de sécurité.",
            data={"os": name, "eol": date},
        ))

    # --- SSH -------------------------------------------------------------
    sshd = meta.get("sshd") or {}
    if sshd:
        if sshd.get("permitrootlogin") in ("yes", "prohibit-password") and \
                sshd.get("passwordauthentication") == "yes":
            findings.append(Finding(
                code="ssh.root_password", severity="critical", host_id=hid,
                title="Connexion root par mot de passe autorisée",
                detail="Cible privilégiée des attaques par force brute.",
                remediation="Dans sshd_config : PermitRootLogin prohibit-password "
                            "et PasswordAuthentication no.",
            ))
        elif sshd.get("passwordauthentication") == "yes":
            findings.append(Finding(
                code="ssh.password", severity="medium", host_id=hid,
                title="Authentification SSH par mot de passe activée",
                remediation="Passe aux clés puis PasswordAuthentication no.",
            ))
        if sshd.get("permitemptypasswords") == "yes":
            findings.append(Finding(
                code="ssh.empty_password", severity="critical", host_id=hid,
                title="Mots de passe vides acceptés en SSH",
                remediation="PermitEmptyPasswords no, immédiatement.",
            ))
        port = sshd.get("port")
        if port and port != "22":
            findings.append(Finding(
                code="ssh.port", severity="info", host_id=hid,
                title=f"SSH écoute sur le port {port}",
                detail="Information : port non standard.",
            ))

    # --- pare-feu ---------------------------------------------------------
    firewall = meta.get("firewall")
    if firewall and not firewall.get("active"):
        findings.append(Finding(
            code="net.firewall", severity="medium", host_id=hid,
            title="Aucun pare-feu actif",
            detail=f"Outil détecté : {firewall.get('tool') or 'aucun'}.",
            remediation="Active ufw ou firewalld et n'ouvre que les ports nécessaires.",
        ))

    # --- ports en écoute ---------------------------------------------------
    for port in meta.get("listening_ports") or []:
        entry = RISKY_PORTS.get(port)
        if not entry:
            continue
        severity, label, remediation = entry
        findings.append(Finding(
            code=f"net.port.{port}", severity=severity, host_id=hid,
            title=f"{label} en écoute (port {port})",
            detail="Le service écoute sur une interface réseau.",
            remediation=remediation,
            data={"port": port},
        ))

    # --- comptes -----------------------------------------------------------
    uid0 = [a for a in (meta.get("uid0_accounts") or []) if a != "root"]
    if uid0:
        findings.append(Finding(
            code="account.uid0", severity="high", host_id=hid,
            title="Compte(s) supplémentaire(s) avec UID 0",
            detail="Comptes concernés : " + ", ".join(uid0),
            remediation="Un seul compte doit avoir l'UID 0. Vérifie /etc/passwd.",
            data={"accounts": uid0},
        ))

    # --- matériel ----------------------------------------------------------
    for disk in meta.get("smart") or []:
        health = (disk.get("health") or "").upper()
        if health and health not in ("PASSED", "OK"):
            findings.append(Finding(
                code=f"hw.smart.{disk['device']}", severity="critical", host_id=hid,
                title=f"Disque {disk['device']} en défaut SMART",
                detail=f"État rapporté : {disk.get('health')}",
                remediation="Sauvegarde immédiatement et remplace le disque.",
                data=disk,
            ))

    failed = meta.get("services_failed") or []
    if failed:
        findings.append(Finding(
            code="svc.failed", severity="medium", host_id=hid,
            title=f"{len(failed)} service(s) systemd en échec",
            detail=", ".join(failed[:6]),
            remediation="Consulte l'onglet Système de l'hôte pour les relancer.",
            data={"services": failed},
        ))

    return findings


def check_containers(containers: list[dict]) -> list[Finding]:
    findings = []
    for container in containers:
        labels = container.get("labels") or {}
        image = container.get("image") or ""
        # Une image « latest » rend impossible de savoir ce qui tourne réellement.
        if image.endswith(":latest") or (":" not in image.split("/")[-1] and image):
            findings.append(Finding(
                code=f"docker.tag.{container['id']}", severity="low",
                host_id=container["host_id"],
                title=f"Conteneur « {container['name']} » sur une image flottante",
                detail=f"Image : {image or 'inconnue'}",
                remediation="Épingle une version précise pour rendre les déploiements reproductibles.",
                data={"image": image},
            ))
        if labels.get("com.docker.compose.project") is None and container.get("state") == "running":
            continue
    return findings


def _eol_status(pretty_name: str) -> tuple[bool, str, str] | None:
    """(support terminé ?, nom, date) si la distribution est connue."""
    lowered = pretty_name.lower()
    for distro, versions in EOL.items():
        if distro not in lowered:
            continue
        match = re.search(r"(\d+(?:\.\d+)?)", pretty_name)
        if not match:
            return None
        version = match.group(1)
        date = versions.get(version)
        if not date:
            # Les versions plus récentes que la table sont supposées supportées.
            return None
        deadline = dt.date.fromisoformat(date)
        today = dt.date.today()
        if today > deadline:
            return (True, pretty_name, date)
        if (deadline - today).days < 180:
            return (False, pretty_name, date)
        return None
    return None


# ------------------------------------------------------------ certificats TLS
async def check_certificate(url: str) -> dict[str, Any] | None:
    """Date d'expiration du certificat d'un service HTTPS."""
    match = re.match(r"^https://([^/:]+)(?::(\d+))?", url)
    if not match:
        return None
    hostname, port = match.group(1), int(match.group(2) or 443)

    def _fetch() -> dict | None:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        try:
            import socket

            with socket.create_connection((hostname, port), timeout=6) as raw:
                with context.wrap_socket(raw, server_hostname=hostname) as tls:
                    return tls.getpeercert()
        except (OSError, ssl.SSLError):
            return None

    cert = await asyncio.get_running_loop().run_in_executor(None, _fetch)
    if not cert or not cert.get("notAfter"):
        return None
    try:
        expires = dt.datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError:
        return None
    issuer = dict(x[0] for x in cert.get("issuer", ())).get("organizationName", "")
    return {"expires_at": expires, "issuer": issuer,
            "days_left": (expires - dt.datetime.now(dt.timezone.utc)).days}


# ------------------------------------------------------------------ synthèse
async def scan() -> dict[str, Any]:
    """Rejoue tous les contrôles et réconcilie l'état des constats en base."""
    hosts = await fetch_all("SELECT * FROM hosts WHERE enabled")
    containers = await fetch_all(
        "SELECT c.*, h.name AS host_name FROM containers c JOIN hosts h ON h.id = c.host_id "
        "WHERE c.kind = 'docker'"
    )
    services = await fetch_all("SELECT * FROM services WHERE enabled")

    findings: list[Finding] = []
    for host in hosts:
        findings.extend(check_host(host))
    findings.extend(check_containers(containers))

    # Certificats : une passe concurrente sur les services en HTTPS.
    https = [s for s in services if str(s["url"]).startswith("https://")]
    if https:
        results = await asyncio.gather(*(check_certificate(s["url"]) for s in https),
                                       return_exceptions=True)
        for service, cert in zip(https, results):
            if not isinstance(cert, dict):
                continue
            await execute(
                "UPDATE services SET ssl_expires_at = :e, ssl_issuer = :i, ssl_checked = now() "
                "WHERE id = :id",
                {"e": cert["expires_at"], "i": cert["issuer"], "id": service["id"]},
            )
            days = cert["days_left"]
            if days < 0:
                findings.append(Finding(
                    code="tls.expired", severity="critical", service_id=service["id"],
                    host_id=service.get("host_id"),
                    title=f"Certificat expiré — {service['name']}",
                    detail=f"Expiré depuis {abs(days)} jour(s).",
                    remediation="Renouvelle le certificat (Let's Encrypt : vérifie le renouvellement auto).",
                    data={"days": days},
                ))
            elif days < 21:
                findings.append(Finding(
                    code="tls.expiring", severity="high" if days < 7 else "medium",
                    service_id=service["id"], host_id=service.get("host_id"),
                    title=f"Certificat bientôt expiré — {service['name']}",
                    detail=f"Expire dans {days} jour(s) ({cert['issuer']}).",
                    remediation="Vérifie le renouvellement automatique.",
                    data={"days": days},
                ))

    # Services web joignables en HTTP simple : signal faible mais utile.
    for service in services:
        if str(service["url"]).startswith("http://") and "localhost" not in service["url"]:
            findings.append(Finding(
                code="tls.plaintext", severity="low", service_id=service["id"],
                host_id=service.get("host_id"),
                title=f"{service['name']} exposé en HTTP",
                detail=service["url"],
                remediation="Passe en HTTPS, ne serait-ce que via un reverse-proxy avec Let's Encrypt.",
            ))

    await _reconcile(findings)
    return await summary()


async def _reconcile(findings: list[Finding]) -> None:
    """Insère ou rafraîchit les constats, et clôt ceux qui ont disparu."""
    now_codes = {(f.host_id or 0, f.service_id or 0, f.code) for f in findings}

    if findings:
        await execute_many(
            """INSERT INTO security_findings
                 (host_id, service_id, code, severity, title, detail, remediation, data, last_seen, resolved_at)
               VALUES (:host_id, :service_id, :code, :severity, :title, :detail, :remediation,
                       CAST(:data AS jsonb), now(), NULL)
               ON CONFLICT (coalesce(host_id, 0), coalesce(service_id, 0), code) DO UPDATE SET
                 severity = EXCLUDED.severity, title = EXCLUDED.title, detail = EXCLUDED.detail,
                 remediation = EXCLUDED.remediation, data = EXCLUDED.data,
                 last_seen = now(), resolved_at = NULL""",
            [{
                "host_id": f.host_id, "service_id": f.service_id, "code": f.code,
                "severity": f.severity, "title": f.title, "detail": f.detail,
                "remediation": f.remediation, "data": json.dumps(f.data, default=str),
            } for f in findings],
        )

    open_rows = await fetch_all(
        "SELECT id, host_id, service_id, code FROM security_findings WHERE resolved_at IS NULL"
    )
    stale = [r["id"] for r in open_rows
             if (r["host_id"] or 0, r["service_id"] or 0, r["code"]) not in now_codes]
    if stale:
        await execute(
            "UPDATE security_findings SET resolved_at = now() "
            "WHERE id = ANY(CAST(:ids AS integer[]))",
            {"ids": stale},
        )
        log.info("%d constat(s) de sécurité résolu(s)", len(stale))


async def summary() -> dict[str, Any]:
    rows = await fetch_all(
        """SELECT f.*, h.name AS host_name, h.kind AS host_kind, s.name AS service_name
           FROM security_findings f
           LEFT JOIN hosts h ON h.id = f.host_id
           LEFT JOIN services s ON s.id = f.service_id
           WHERE f.resolved_at IS NULL AND NOT f.muted
           ORDER BY f.severity, f.last_seen DESC"""
    )
    rows.sort(key=lambda r: SEVERITY_ORDER.get(r["severity"], 9))

    by_severity: dict[str, int] = {}
    by_host: dict[int, dict[str, Any]] = {}
    for row in rows:
        by_severity[row["severity"]] = by_severity.get(row["severity"], 0) + 1
        if row["host_id"]:
            entry = by_host.setdefault(row["host_id"], {
                "host_id": row["host_id"], "name": row["host_name"],
                "kind": row["host_kind"], "count": 0, "score": 100, "worst": "info",
            })
            entry["count"] += 1
            entry["score"] = max(0, entry["score"] - SEVERITY_WEIGHT.get(row["severity"], 0))
            if SEVERITY_ORDER.get(row["severity"], 9) < SEVERITY_ORDER.get(entry["worst"], 9):
                entry["worst"] = row["severity"]

    # Note globale : moyenne des notes par hôte, plancher à 0.
    scores = [h["score"] for h in by_host.values()]
    total_hosts = await fetch_all("SELECT count(*) AS n FROM hosts WHERE enabled")
    clean = max(0, (total_hosts[0]["n"] if total_hosts else 0) - len(by_host))
    global_score = round((sum(scores) + clean * 100) / max(1, len(scores) + clean))

    muted = await fetch_all(
        "SELECT count(*) AS n FROM security_findings WHERE muted AND resolved_at IS NULL"
    )
    resolved = await fetch_all(
        "SELECT count(*) AS n FROM security_findings WHERE resolved_at > now() - interval '7 days'"
    )
    return {
        "findings": rows,
        "by_host": sorted(by_host.values(), key=lambda h: h["score"]),
        "summary": {
            "score": global_score,
            "total": len(rows),
            "by_severity": by_severity,
            "hosts_affected": len(by_host),
            "hosts_clean": clean,
            "muted": muted[0]["n"] if muted else 0,
            "resolved_7d": resolved[0]["n"] if resolved else 0,
        },
    }


async def run_periodic(interval: float = 900.0) -> None:
    await asyncio.sleep(45)  # laisse le premier cycle lent peupler les métadonnées
    while True:
        try:
            result = await scan()
            bus.publish("security", {"summary": result["summary"]})
        except Exception as exc:  # noqa: BLE001
            log.warning("Analyse de sécurité : %s", exc)
        await asyncio.sleep(interval)
