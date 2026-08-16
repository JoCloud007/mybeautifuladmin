from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr, Field

from .. import notify
from ..security import current_user

router = APIRouter(prefix="/notifications", tags=["notifications"])


class ConfigIn(BaseModel):
    enabled: bool | None = None
    host: str | None = None
    port: int | None = Field(default=None, ge=1, le=65535)
    security: Literal["none", "starttls", "ssl"] | None = None
    username: str | None = None
    # Vide = on conserve le mot de passe déjà enregistré.
    password: str | None = None
    from_addr: str | None = None
    to_addrs: list[EmailStr] | None = None
    triggers: list[str] | None = None
    cooldown_minutes: int | None = Field(default=None, ge=0, le=1440)


@router.get("")
async def get_config(user: dict = Depends(current_user)) -> dict:
    """Configuration courante — le mot de passe n'est jamais renvoyé."""
    return {"config": await notify.get_config(), "triggers": notify.TRIGGERS}


@router.put("")
async def save_config(payload: ConfigIn, user: dict = Depends(current_user)) -> dict:
    fields = payload.model_dump(exclude_unset=True)
    if "to_addrs" in fields and fields["to_addrs"] is not None:
        fields["to_addrs"] = [str(a) for a in fields["to_addrs"]]
    if "triggers" in fields and fields["triggers"] is not None:
        unknown = set(fields["triggers"]) - set(notify.TRIGGERS)
        if unknown:
            raise HTTPException(status.HTTP_400_BAD_REQUEST,
                                f"Déclencheur inconnu : {', '.join(sorted(unknown))}")
    config = await notify.save_config(fields)

    from ..poller import log_event
    await log_event(None, "info", "notifications",
                    f"Configuration des notifications modifiée par {user['username']}",
                    {"actif": config.get("enabled"), "destinataires": len(config.get("to_addrs") or [])})
    return {"config": config}


@router.post("/test")
async def test(payload: ConfigIn, user: dict = Depends(current_user)) -> dict:
    """Envoie un message de vérification sans enregistrer la configuration."""
    fields = payload.model_dump(exclude_unset=True, exclude_none=True)
    if "to_addrs" in fields:
        fields["to_addrs"] = [str(a) for a in fields["to_addrs"]]
    if not fields.get("to_addrs") and not (await notify.get_config()).get("to_addrs"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aucun destinataire renseigné")
    return await notify.test(fields)
