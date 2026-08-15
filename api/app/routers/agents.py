from __future__ import annotations

import json
from typing import Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import BaseModel, Field

from .. import agents as engine
from ..db import execute, fetch_all, fetch_one
from ..scheduler import next_occurrence, validate_cron
from ..security import current_user

router = APIRouter(prefix="/agents", tags=["agents"])

Mode = Literal["observe", "suggest", "auto"]
ScopeKind = Literal["all", "tag", "kind", "host"]


class AgentIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    description: str | None = None
    role: str = "custom"
    endpoint_id: int
    model: str = Field(min_length=1)
    system_prompt: str | None = None
    mode: Mode = "observe"
    scope_kind: ScopeKind = "all"
    scope_value: str | None = None
    allowed_actions: list[str] = []
    max_actions: int = Field(3, ge=1, le=10)
    cron: str | None = None
    enabled: bool = True


class AgentPatch(BaseModel):
    name: str | None = None
    description: str | None = None
    role: str | None = None
    endpoint_id: int | None = None
    model: str | None = None
    system_prompt: str | None = None
    mode: Mode | None = None
    scope_kind: ScopeKind | None = None
    scope_value: str | None = None
    allowed_actions: list[str] | None = None
    max_actions: int | None = Field(default=None, ge=1, le=10)
    cron: str | None = None
    enabled: bool | None = None


class DecisionIn(BaseModel):
    approve: bool


def _validate(payload: dict) -> None:
    unknown = set(payload.get("allowed_actions") or []) - set(engine.ACTION_CATALOG)
    if unknown:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"Action(s) inconnue(s) : {', '.join(sorted(unknown))}")
    if payload.get("scope_kind") != "all" and not payload.get("scope_value"):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Périmètre incomplet")
    if payload.get("cron"):
        try:
            validate_cron(payload["cron"])
        except ValueError as exc:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc


@router.get("/catalog")
async def catalog(user: dict = Depends(current_user)) -> dict:
    """Actions disponibles, rôles préconfigurés et endpoints IA utilisables."""
    endpoints = await fetch_all(
        "SELECT id, name, url, status, meta FROM ai_endpoints WHERE enabled ORDER BY name"
    )
    from ..bus import bus

    live = bus.latest("ai.")
    for endpoint in endpoints:
        snap = live.get(f"ai.{endpoint['id']}", {})
        endpoint["models"] = [m["name"] for m in (snap.get("models") or [])]
        endpoint["status"] = snap.get("status", endpoint["status"])

    return {
        "actions": engine.ACTION_CATALOG,
        "roles": engine.ROLES,
        "endpoints": endpoints,
        "modes": {
            "observe": "Analyse seulement — aucune action n'est proposée.",
            "suggest": "Propose des actions ; chacune attend ta validation.",
            "auto": "Exécute les actions réversibles autorisées, propose le reste.",
        },
    }


@router.get("")
async def list_agents(user: dict = Depends(current_user)) -> dict:
    agents = await fetch_all(
        "SELECT a.*, e.name AS endpoint_name, e.status AS endpoint_status "
        "FROM agents a LEFT JOIN ai_endpoints e ON e.id = a.endpoint_id "
        "ORDER BY a.enabled DESC, a.name"
    )
    for agent in agents:
        agent["scope_count"] = len(await engine.scope_hosts(agent))
        agent["pending"] = await fetch_one(
            "SELECT count(*) AS n FROM agent_proposals WHERE agent_id = :a AND state = 'pending'",
            {"a": agent["id"]},
        )
        agent["pending"] = (agent["pending"] or {}).get("n", 0)

    pending = await fetch_all(
        """SELECT p.*, a.name AS agent_name, h.name AS host_name
           FROM agent_proposals p
           JOIN agents a ON a.id = p.agent_id
           LEFT JOIN hosts h ON h.id = p.host_id
           WHERE p.state = 'pending' ORDER BY p.created_at DESC LIMIT 50"""
    )
    for proposal in pending:
        spec = engine.ACTION_CATALOG.get(proposal["action"], {})
        proposal["label"] = spec.get("label", proposal["action"])
        proposal["auto_capable"] = spec.get("auto", False)

    return {"agents": agents, "pending": pending, "actions": engine.ACTION_CATALOG}


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_agent(payload: AgentIn, user: dict = Depends(current_user)) -> dict:
    data = payload.model_dump()
    _validate(data)

    agent_id = await execute(
        """INSERT INTO agents (name, description, role, endpoint_id, model, system_prompt,
                               mode, scope_kind, scope_value, allowed_actions, max_actions,
                               cron, enabled, next_run)
           VALUES (:name, :description, :role, :endpoint_id, :model, :system_prompt,
                   :mode, :scope_kind, :scope_value, :allowed_actions, :max_actions,
                   :cron, :enabled, :next_run) RETURNING id""",
        {**data, "next_run": next_occurrence(data["cron"]) if data.get("cron") else None},
    )
    return await fetch_one("SELECT * FROM agents WHERE id = :id", {"id": agent_id})


@router.patch("/{agent_id}")
async def update_agent(agent_id: int, payload: AgentPatch,
                       user: dict = Depends(current_user)) -> dict:
    current = await _require(agent_id)
    fields = payload.model_dump(exclude_unset=True)
    _validate({**current, **fields})

    sets, params = [], {"id": agent_id}
    for key, value in fields.items():
        sets.append(f"{key} = :{key}")
        params[key] = value
    if "cron" in fields:
        sets.append("next_run = :next_run")
        params["next_run"] = next_occurrence(fields["cron"]) if fields["cron"] else None
    if not sets:
        return current

    await execute(f"UPDATE agents SET {', '.join(sets)} WHERE id = :id", params)
    return await fetch_one("SELECT * FROM agents WHERE id = :id", {"id": agent_id})


@router.delete("/{agent_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_agent(agent_id: int, user: dict = Depends(current_user)) -> Response:
    await _require(agent_id)
    await execute("DELETE FROM agents WHERE id = :id", {"id": agent_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{agent_id}/run")
async def run_now(agent_id: int, user: dict = Depends(current_user)) -> dict:
    agent = await _require(agent_id)
    if agent["running"]:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet agent est déjà en cours d'exécution")
    return await engine.run_agent(agent, trigger="manuel", username=user["username"])


@router.get("/{agent_id}/runs")
async def runs(agent_id: int, limit: int = 20, user: dict = Depends(current_user)) -> list[dict]:
    await _require(agent_id)
    history = await fetch_all(
        "SELECT id, trigger, status, summary, analysis, error, duration_s, started_at, ended_at "
        "FROM agent_runs WHERE agent_id = :a ORDER BY started_at DESC LIMIT :l",
        {"a": agent_id, "l": limit},
    )
    for run in history:
        run["proposals"] = await fetch_all(
            "SELECT p.*, h.name AS host_name FROM agent_proposals p "
            "LEFT JOIN hosts h ON h.id = p.host_id WHERE p.run_id = :r ORDER BY p.id",
            {"r": run["id"]},
        )
        for proposal in run["proposals"]:
            proposal["label"] = engine.ACTION_CATALOG.get(proposal["action"], {}).get(
                "label", proposal["action"]
            )
    return history


@router.post("/proposals/{proposal_id}/decide")
async def decide(proposal_id: int, payload: DecisionIn,
                 user: dict = Depends(current_user)) -> dict:
    proposal = await fetch_one(
        "SELECT * FROM agent_proposals WHERE id = :id", {"id": proposal_id}
    )
    if not proposal:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Proposition introuvable")
    if proposal["state"] != "pending":
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Cette proposition est déjà « {proposal['state']} »")

    if not payload.approve:
        await execute(
            "UPDATE agent_proposals SET state='rejected', decided_by=:u, decided_at=now() "
            "WHERE id=:id",
            {"u": user["username"], "id": proposal_id},
        )
        return {"ok": True, "state": "rejected"}

    try:
        result = await engine.execute_proposal(proposal_id, user["username"])
    except engine.AgentError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from exc
    return {"ok": True, "state": "executed", **result}


@router.post("/preview")
async def preview(payload: AgentIn, user: dict = Depends(current_user)) -> dict:
    """Contexte et invite qui seraient envoyés au modèle, sans rien exécuter."""
    data = payload.model_dump()
    _validate(data)
    hosts = await engine.scope_hosts(data)
    context = await engine.build_context({**data, "id": 0})
    system, user_prompt = engine.build_prompt(data, context)
    return {
        "hosts": [{"id": h["id"], "name": h["name"], "kind": h["kind"]} for h in hosts],
        "system_prompt": system,
        "context": context,
        "estimated_chars": len(system) + len(user_prompt),
    }


async def _require(agent_id: int) -> dict:
    agent = await fetch_one("SELECT * FROM agents WHERE id = :id", {"id": agent_id})
    if not agent:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Agent introuvable")
    return agent
