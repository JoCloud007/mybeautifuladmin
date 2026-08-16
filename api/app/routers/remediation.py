from __future__ import annotations

import json
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from .. import remediation as engine
from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/remediation", tags=["remédiation"])

ScopeKind = Literal["all", "tag", "kind", "host"]


class RuleIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str | None = None
    trigger: str
    action: str
    params: dict[str, Any] = {}
    scope_kind: ScopeKind = "all"
    scope_value: str | None = None
    confirm_seconds: int = Field(300, ge=30, le=86400)
    cooldown_seconds: int = Field(1800, ge=60, le=86400)
    max_per_day: int = Field(3, ge=1, le=50)
    allow_destructive: bool = False
    enabled: bool = True


class RulePatch(BaseModel):
    name: str | None = None
    description: str | None = None
    trigger: str | None = None
    action: str | None = None
    params: dict[str, Any] | None = None
    scope_kind: ScopeKind | None = None
    scope_value: str | None = None
    confirm_seconds: int | None = Field(default=None, ge=30, le=86400)
    cooldown_seconds: int | None = Field(default=None, ge=60, le=86400)
    max_per_day: int | None = Field(default=None, ge=1, le=50)
    allow_destructive: bool | None = None
    enabled: bool | None = None


def _validate(data: dict) -> None:
    if data.get("trigger") not in engine.TRIGGERS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"Déclencheur inconnu : {data.get('trigger')}")
    spec = engine.ACTIONS.get(data.get("action"))
    if not spec:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Action inconnue : {data.get('action')}")
    missing = [p for p in spec["params"] if not (data.get("params") or {}).get(p)]
    if missing:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"Paramètre(s) requis pour cette action : {', '.join(missing)}")
    if spec["destructive"] and not data.get("allow_destructive"):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"« {spec['label']} » interrompt un service. Coche « autoriser les actions "
            "destructives » pour l'utiliser dans une règle automatique.",
        )
    if data.get("scope_kind") != "all" and not data.get("scope_value"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Périmètre incomplet")


@router.get("/catalog")
async def catalog(user: dict = Depends(current_user)) -> dict:
    agents = await fetch_all("SELECT id, name, mode FROM agents WHERE enabled ORDER BY name")
    return {"triggers": engine.TRIGGERS, "actions": engine.ACTIONS, "agents": agents}


@router.get("")
async def list_rules(user: dict = Depends(current_user)) -> dict:
    rules = await fetch_all("SELECT * FROM remediation_rules ORDER BY enabled DESC, name")
    for rule in rules:
        rule["trigger_label"] = engine.TRIGGERS.get(rule["trigger"], {}).get("label", rule["trigger"])
        rule["action_label"] = engine.ACTIONS.get(rule["action"], {}).get("label", rule["action"])
        stats = await fetch_one(
            "SELECT count(*) AS total, "
            "count(*) FILTER (WHERE status = 'success') AS ok, "
            "count(*) FILTER (WHERE started_at > now() - interval '24 hours') AS today "
            "FROM remediation_runs WHERE rule_id = :r",
            {"r": rule["id"]},
        )
        rule["stats"] = stats or {}

    runs = await fetch_all(
        "SELECT r.*, h.name AS host_name, rr.name AS rule_name "
        "FROM remediation_runs r "
        "LEFT JOIN hosts h ON h.id = r.host_id "
        "LEFT JOIN remediation_rules rr ON rr.id = r.rule_id "
        "ORDER BY r.started_at DESC LIMIT 60"
    )
    return {"rules": rules, "runs": runs}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_rule(payload: RuleIn, user: dict = Depends(current_user)) -> dict:
    data = payload.model_dump()
    _validate(data)
    rule_id = await execute(
        """INSERT INTO remediation_rules
             (name, description, trigger, action, params, scope_kind, scope_value,
              confirm_seconds, cooldown_seconds, max_per_day, allow_destructive, enabled)
           VALUES (:name, :description, :trigger, :action, CAST(:params AS jsonb),
                   :scope_kind, :scope_value, :confirm_seconds, :cooldown_seconds,
                   :max_per_day, :allow_destructive, :enabled) RETURNING id""",
        {**data, "params": json.dumps(data["params"])},
    )
    return await fetch_one("SELECT * FROM remediation_rules WHERE id = :id", {"id": rule_id})


@router.patch("/{rule_id}")
async def update_rule(rule_id: int, payload: RulePatch,
                      user: dict = Depends(current_user)) -> dict:
    current = await _require(rule_id)
    fields = payload.model_dump(exclude_unset=True)
    _validate({**current, **fields})

    sets, params = [], {"id": rule_id}
    for key, value in fields.items():
        if key == "params":
            sets.append("params = CAST(:params AS jsonb)")
            params["params"] = json.dumps(value)
        else:
            sets.append(f"{key} = :{key}")
            params[key] = value
    if not sets:
        return current
    await execute(f"UPDATE remediation_rules SET {', '.join(sets)} WHERE id = :id", params)
    return await fetch_one("SELECT * FROM remediation_rules WHERE id = :id", {"id": rule_id})


@router.delete("/{rule_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_rule(rule_id: int, user: dict = Depends(current_user)) -> Response:
    await _require(rule_id)
    await execute("DELETE FROM remediation_rules WHERE id = :id", {"id": rule_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{rule_id}/run")
async def run_now(rule_id: int, user: dict = Depends(current_user)) -> dict:
    rule = await _require(rule_id)
    try:
        return await engine.run_rule(rule, manual=True)
    except engine.RemediationError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc


@router.post("/preview")
async def preview(payload: RuleIn, user: dict = Depends(current_user)) -> dict:
    """Cibles que la règle traiterait maintenant, sans rien appliquer."""
    data = payload.model_dump()
    _validate(data)
    targets = await engine._matching_targets({**data, "id": 0})
    return {
        "targets": [{"id": t.get("id"), "name": t.get("name"),
                     "detail": t.get("service_name") or t.get("container_name")
                     or t.get("finding_title") or t.get("alert_message")}
                    for t in targets],
        "count": len(targets),
    }


async def _require(rule_id: int) -> dict:
    rule = await fetch_one("SELECT * FROM remediation_rules WHERE id = :id", {"id": rule_id})
    if not rule:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Règle introuvable")
    return rule
