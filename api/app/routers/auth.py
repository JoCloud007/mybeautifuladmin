from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from ..db import execute, fetch_one
from ..security import create_token, current_user, hash_password, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginPayload(BaseModel):
    username: str
    password: str


class PasswordPayload(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8)


@router.post("/login")
async def login(payload: LoginPayload, response: Response) -> dict:
    user = await fetch_one(
        "SELECT id, username, role, password_hash FROM users WHERE username = :u",
        {"u": payload.username},
    )
    if not user or not verify_password(payload.password, user["password_hash"]):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Identifiants invalides")
    token = create_token(user["username"], user["role"])
    response.set_cookie(
        "mba_token", token, httponly=True, samesite="lax", max_age=7 * 24 * 3600, path="/"
    )
    return {"token": token, "user": {"username": user["username"], "role": user["role"]}}


@router.post("/logout")
async def logout(response: Response) -> dict:
    response.delete_cookie("mba_token", path="/")
    return {"ok": True}


@router.get("/me")
async def me(user: dict = Depends(current_user)) -> dict:
    return user


@router.post("/password")
async def change_password(payload: PasswordPayload, user: dict = Depends(current_user)) -> dict:
    row = await fetch_one("SELECT password_hash FROM users WHERE id = :id", {"id": user["id"]})
    if not row or not verify_password(payload.current_password, row["password_hash"]):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mot de passe actuel incorrect")
    await execute(
        "UPDATE users SET password_hash = :h WHERE id = :id",
        {"h": hash_password(payload.new_password), "id": user["id"]},
    )
    return {"ok": True}
