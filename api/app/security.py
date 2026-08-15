"""Authentification : hachage des mots de passe, jetons JWT, dépendances FastAPI."""
from __future__ import annotations

import datetime as dt

import bcrypt
import jwt
from fastapi import Depends, HTTPException, Query, Request, WebSocket, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import settings
from .db import fetch_one

ALGO = "HS256"
TOKEN_TTL = dt.timedelta(days=7)
bearer = HTTPBearer(auto_error=False)


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode(), hashed.encode())
    except ValueError:
        return False


def create_token(username: str, role: str) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    payload = {"sub": username, "role": role, "iat": now, "exp": now + TOKEN_TTL}
    return jwt.encode(payload, settings.secret_key, algorithm=ALGO)


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, settings.secret_key, algorithms=[ALGO])
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"Token invalide: {exc}") from exc


async def current_user(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> dict:
    token = creds.credentials if creds else request.cookies.get("mba_token")
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Authentification requise")
    claims = decode_token(token)
    user = await fetch_one("SELECT id, username, role FROM users WHERE username = :u", {"u": claims["sub"]})
    if not user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Utilisateur inconnu")
    return user


async def ws_user(websocket: WebSocket, token: str | None = Query(default=None)) -> dict:
    """Auth pour les WebSockets : ?token=... ou cookie."""
    raw = token or websocket.cookies.get("mba_token")
    if not raw:
        await websocket.close(code=4401)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Token manquant")
    try:
        claims = decode_token(raw)
    except HTTPException:
        await websocket.close(code=4401)
        raise
    user = await fetch_one("SELECT id, username, role FROM users WHERE username = :u", {"u": claims["sub"]})
    if not user:
        await websocket.close(code=4401)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Utilisateur inconnu")
    return user
