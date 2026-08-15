from __future__ import annotations

from cryptography.fernet import Fernet, InvalidToken

from .config import settings

_fernet = Fernet(settings.vault_key.encode())


def encrypt(value: str | None) -> str | None:
    if value is None or value == "":
        return None
    return _fernet.encrypt(value.encode()).decode()


def decrypt(value: str | None) -> str | None:
    if not value:
        return None
    try:
        return _fernet.decrypt(value.encode()).decode()
    except InvalidToken:
        return None
