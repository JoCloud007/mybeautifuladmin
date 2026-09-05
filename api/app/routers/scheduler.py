from __future__ import annotations

import json
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field, field_validator

from .. import scheduler as engine
from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/schedules", tags=["planificateur"])

Action = Literal["upgrade", "reboot", "shutdown", "service", "container", "prune", "command"]
TargetKind = Literal["host", "tag", "kind", "all"]


def _csv(value: Any) -> Any:
    """Une planification peut viser plusieurs cibles : l'interface envoie une
    liste, la base stocke une chaîne séparée par des virgules."""
    if isinstance(value, (list, tuple, set)):
        joined = ",".join(sorted({str(v).strip() for v in value if str(v).strip()}))
        return joined or None
    return value


class ScheduleIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    action: Action
    target_kind: TargetKind = "host"
    target_value: str | None = None
    params: dict[str, Any] = {}
    cron: str = Field(min_length=5)
    enabled: bool = True

    @field_validator("target_value", mode="before")
    @classmethod
    def _normalize_target(cls, value: Any) -> Any:
        return _csv(value)


class SchedulePatch(BaseModel):
    name: str | None = None
    action: Action | None = None
    target_kind: TargetKind | None = None
    target_value: str | None = None
    params: dict[str, Any] | None = None
    cron: str | None = None
    enabled: bool | None = None

    @field_validator("target_value", mode="before")
    @classmethod
    def _normalize_target(cls, value: Any) -> Any:
        return _csv(value)


def _validate(action: str, target_kind: str, target_value: str | None, params: dict) -> None:
    if target_kind != "all" and not target_value:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Cible manquante pour cette planification")
    if action == "service" and not params.get("service"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Nom du service systemd requis")
    if action == "container" and not params.get("container"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Identifiant du conteneur requis")
    if action == "command" and not params.get("command"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Commande requise")


@router.get("")
async def list_schedules(user: dict = Depends(current_user)) -> dict:
    schedules = await fetch_all("SELECT * FROM schedules ORDER BY enabled DESC, next_run")
    for schedule in schedules:
        try:
            hosts = await engine.resolve_targets(schedule)
        except Exception:  # noqa: BLE001
            hosts = []
        schedule["targets"] = len(hosts)
        schedule["target_names"] = [h["name"] for h in hosts]
        schedule["target_values"] = engine.target_values(schedule)
        schedule["description"] = engine.describe(schedule, hosts)
    return {
        "schedules": schedules,
        "actions": engine.ACTIONS,
        "timezone": str(engine.timezone()),
    }


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_schedule(payload: ScheduleIn, user: dict = Depends(current_user)) -> dict:
    try:
        engine.validate_cron(payload.cron)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc
    _validate(payload.action, payload.target_kind, payload.target_value, payload.params)

    schedule_id = await execute(
        """INSERT INTO schedules (name, action, target_kind, target_value, params, cron,
                                  enabled, next_run)
           VALUES (:name, :action, :tk, :tv, CAST(:params AS jsonb), :cron, :enabled, :next)
           RETURNING id""",
        {"name": payload.name, "action": payload.action, "tk": payload.target_kind,
         "tv": payload.target_value, "params": json.dumps(payload.params),
         "cron": payload.cron, "enabled": payload.enabled,
         "next": engine.next_occurrence(payload.cron)},
    )
    return await fetch_one("SELECT * FROM schedules WHERE id = :id", {"id": schedule_id})


@router.patch("/{schedule_id}")
async def update_schedule(schedule_id: int, payload: SchedulePatch,
                          user: dict = Depends(current_user)) -> dict:
    current = await fetch_one("SELECT * FROM schedules WHERE id = :id", {"id": schedule_id})
    if not current:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Planification introuvable")

    fields = payload.model_dump(exclude_unset=True)
    merged = {**current, **fields}
    if "cron" in fields:
        try:
            engine.validate_cron(fields["cron"])
        except ValueError as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc
    _validate(merged["action"], merged["target_kind"], merged.get("target_value"),
              merged.get("params") or {})

    sets, params = [], {"id": schedule_id}
    for key, value in fields.items():
        if key == "params":
            sets.append("params = CAST(:params AS jsonb)")
            params["params"] = json.dumps(value)
        else:
            sets.append(f"{key} = :{key}")
            params[key] = value
    # Changer le cron (ou réactiver) recalcule l'échéance.
    if "cron" in fields or fields.get("enabled"):
        sets.append("next_run = :next")
        params["next"] = engine.next_occurrence(merged["cron"])

    await execute(f"UPDATE schedules SET {', '.join(sets)} WHERE id = :id", params)
    return await fetch_one("SELECT * FROM schedules WHERE id = :id", {"id": schedule_id})


@router.delete("/{schedule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_schedule(schedule_id: int, user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM schedules WHERE id = :id", {"id": schedule_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{schedule_id}/run")
async def run_schedule(schedule_id: int, user: dict = Depends(current_user)) -> dict:
    try:
        return await engine.run_now(schedule_id, user["username"])
    except ValueError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(exc)) from exc


@router.post("/preview")
async def preview(payload: ScheduleIn, user: dict = Depends(current_user)) -> dict:
    """Cibles concernées et cinq prochaines échéances, avant d'enregistrer."""
    try:
        engine.validate_cron(payload.cron)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc

    hosts = await engine.resolve_targets(payload.model_dump())
    runs, cursor = [], None
    for _ in range(5):
        cursor = engine.next_occurrence(payload.cron, cursor)
        runs.append(cursor)
    return {
        "targets": [{"id": h["id"], "name": h["name"], "kind": h["kind"]} for h in hosts],
        "next_runs": runs,
    }
