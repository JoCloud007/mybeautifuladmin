"""Notifications sortantes.

Un seul canal pour l'instant — le courriel — mais l'aiguillage est isolé pour
qu'un autre transport (webhook, messagerie) puisse s'y greffer sans toucher aux
appelants. La configuration vit dans la table `settings`, le mot de passe SMTP
dans le coffre chiffré.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import smtplib
import ssl
from email.message import EmailMessage
from typing import Any

from .db import execute, fetch_all, fetch_one
from .vault import decrypt, encrypt

log = logging.getLogger("mba.notify")

SETTINGS_KEY = "notifications"

# Évènements notifiables, du plus urgent au plus anodin.
TRIGGERS: dict[str, str] = {
    "host_down": "Machine injoignable",
    "host_up": "Machine de nouveau joignable",
    "alert_firing": "Alerte déclenchée (seuil dépassé)",
    "service_down": "Service web en panne",
    "security_critical": "Constat de sécurité critique",
    "backup_risk": "Risque de sauvegarde détecté",
    "cloud_quota": "Seuil de stockage cloud dépassé",
    "action_failed": "Action d'administration en échec",
    "agent_proposal": "Un agent IA propose une action",
    "remediation": "Auto-remédiation exécutée",
}

DEFAULT_CONFIG: dict[str, Any] = {
    "enabled": False,
    "host": "",
    "port": 587,
    "security": "starttls",   # none | starttls | ssl
    "username": "",
    "from_addr": "",
    "to_addrs": [],
    "triggers": ["host_down", "alert_firing", "security_critical", "action_failed"],
    # Anti-répétition : un même sujet n'est pas renvoyé avant ce délai.
    "cooldown_minutes": 30,
}


class NotifyError(RuntimeError):
    pass


# ------------------------------------------------------------ configuration
async def get_config(include_secret: bool = False) -> dict[str, Any]:
    row = await fetch_one("SELECT value FROM settings WHERE key = :k", {"k": SETTINGS_KEY})
    config = {**DEFAULT_CONFIG, **((row or {}).get("value") or {})}
    stored = config.pop("password_enc", None)
    config["has_password"] = bool(stored)
    if include_secret:
        config["password"] = decrypt(stored) if stored else ""
    return config


async def save_config(payload: dict[str, Any]) -> dict[str, Any]:
    current = await fetch_one("SELECT value FROM settings WHERE key = :k", {"k": SETTINGS_KEY})
    stored = (current or {}).get("value") or {}

    merged = {**DEFAULT_CONFIG, **stored}
    for key, value in payload.items():
        if key == "password":
            # Un mot de passe vide conserve celui déjà enregistré.
            if value:
                merged["password_enc"] = encrypt(value)
            continue
        if key in DEFAULT_CONFIG:
            merged[key] = value

    await execute(
        "INSERT INTO settings (key, value) VALUES (:k, CAST(:v AS jsonb)) "
        "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        {"k": SETTINGS_KEY, "v": json.dumps(merged, default=str)},
    )
    return await get_config()


# --------------------------------------------------------------- expédition
def _send_sync(config: dict[str, Any], subject: str, body: str) -> None:
    """Envoi bloquant, déporté dans un thread par l'appelant."""
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = config["from_addr"] or config["username"]
    message["To"] = ", ".join(config["to_addrs"])
    message.set_content(body)

    host, port = config["host"], int(config["port"])
    security = config.get("security", "starttls")
    context = ssl.create_default_context()

    try:
        if security == "ssl":
            server = smtplib.SMTP_SSL(host, port, timeout=20, context=context)
        else:
            server = smtplib.SMTP(host, port, timeout=20)
        with server:
            server.ehlo()
            if security == "starttls":
                server.starttls(context=context)
                server.ehlo()
            if config.get("username") and config.get("password"):
                server.login(config["username"], config["password"])
            server.send_message(message)
    except smtplib.SMTPAuthenticationError as exc:
        raise NotifyError(
            f"Authentification SMTP refusée ({exc.smtp_code}). "
            "Sur Gmail ou iCloud, il faut un mot de passe d'application, pas le mot de passe du compte."
        ) from exc
    except smtplib.SMTPException as exc:
        raise NotifyError(f"Erreur SMTP : {exc}") from exc
    except (OSError, ssl.SSLError) as exc:
        raise NotifyError(
            f"Serveur SMTP injoignable ({exc}). Vérifie l'hôte, le port et le mode de chiffrement — "
            "587 va avec STARTTLS, 465 avec SSL."
        ) from exc


async def send(subject: str, body: str, config: dict[str, Any] | None = None) -> None:
    config = config or await get_config(include_secret=True)
    if not config.get("host") or not config.get("to_addrs"):
        raise NotifyError("Configuration SMTP incomplète (serveur et destinataire requis)")
    await asyncio.get_running_loop().run_in_executor(None, _send_sync, config, subject, body)


async def test(payload: dict[str, Any]) -> dict[str, Any]:
    """Envoie un message de vérification avec la configuration proposée."""
    config = {**await get_config(include_secret=True), **{k: v for k, v in payload.items() if v != ""}}
    if payload.get("password"):
        config["password"] = payload["password"]
    try:
        await send(
            "[MBA] Test de notification",
            "Ce message confirme que MyBeautifulAdmin sait joindre ta boîte mail.\n\n"
            "Si tu le reçois, la configuration SMTP est bonne.",
            config,
        )
    except NotifyError as exc:
        return {"ok": False, "detail": str(exc)}
    return {"ok": True, "detail": f"Message envoyé à {', '.join(config['to_addrs'])}"}


# -------------------------------------------------------------- aiguillage
_last_sent: dict[str, dt.datetime] = {}


async def dispatch(trigger: str, subject: str, body: str,
                   dedupe_key: str | None = None) -> bool:
    """Notifie si le déclencheur est activé et hors période de silence."""
    try:
        config = await get_config(include_secret=True)
    except Exception as exc:  # noqa: BLE001
        log.warning("Configuration de notification illisible : %s", exc)
        return False

    if not config.get("enabled") or trigger not in (config.get("triggers") or []):
        return False

    key = dedupe_key or f"{trigger}:{subject}"
    cooldown = dt.timedelta(minutes=int(config.get("cooldown_minutes") or 0))
    now = dt.datetime.now(dt.timezone.utc)
    if cooldown and (last := _last_sent.get(key)) and now - last < cooldown:
        log.debug("Notification « %s » retenue (silence en cours)", key)
        return False

    try:
        await send(f"[MBA] {subject}", body, config)
        _last_sent[key] = now
        return True
    except NotifyError as exc:
        log.warning("Notification non envoyée : %s", exc)
        return False


def format_event(host: str | None, level: str, message: str,
                 detail: dict | None = None) -> str:
    """Corps de message lisible, sans dépendre du HTML."""
    lines = [message, ""]
    if host:
        lines.append(f"Machine : {host}")
    lines.append(f"Niveau  : {level}")
    lines.append(f"Quand   : {dt.datetime.now().strftime('%d/%m/%Y %H:%M')}")
    if detail:
        lines += ["", "Détail :"]
        lines += [f"  {k} : {v}" for k, v in detail.items()]
    lines += ["", "— MyBeautifulAdmin"]
    return "\n".join(lines)
