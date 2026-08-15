from __future__ import annotations

import os
import secrets
from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings

KEY_DIR = Path("/data/keys")


class Settings(BaseSettings):
    database_url: str = "postgresql+asyncpg://mba:mba_dev_password@db:5432/mba"
    secret_key: str = ""
    vault_key: str = ""
    admin_user: str = "admin"
    admin_password: str = "admin"
    poll_interval: int = 5
    discovery_subnets: str = ""
    log_level: str = "INFO"

    # Fenêtre de rétention en mémoire pour le flux temps réel (en points)
    live_buffer: int = 240

    model_config = {"env_file": None, "extra": "ignore"}


def _persisted(name: str, generator) -> str:
    """Lit une clé depuis le volume, ou la génère et la persiste."""
    KEY_DIR.mkdir(parents=True, exist_ok=True)
    path = KEY_DIR / name
    if path.exists():
        return path.read_text().strip()
    value = generator()
    path.write_text(value)
    path.chmod(0o600)
    return value


@lru_cache
def get_settings() -> Settings:
    s = Settings(
        database_url=os.getenv("DATABASE_URL", Settings().database_url),
        secret_key=os.getenv("SECRET_KEY", ""),
        vault_key=os.getenv("VAULT_KEY", ""),
        admin_user=os.getenv("ADMIN_USER", "admin"),
        admin_password=os.getenv("ADMIN_PASSWORD", "admin"),
        poll_interval=int(os.getenv("POLL_INTERVAL", "5") or 5),
        discovery_subnets=os.getenv("DISCOVERY_SUBNETS", ""),
        log_level=os.getenv("LOG_LEVEL", "INFO"),
    )
    if not s.secret_key or s.secret_key.startswith("change-me"):
        s.secret_key = _persisted("jwt.key", lambda: secrets.token_hex(32))
    if not s.vault_key:
        from cryptography.fernet import Fernet

        s.vault_key = _persisted("vault.key", lambda: Fernet.generate_key().decode())
    return s


settings = get_settings()
