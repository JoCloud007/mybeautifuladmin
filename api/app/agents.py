"""Agents IA : analyse autonome de l'infra et actions encadrées.

Un agent reçoit un état de l'infrastructure (métriques, constats de sécurité,
écarts de sauvegarde, mises à jour en attente) et renvoie un diagnostic plus une
liste d'actions. Trois niveaux d'autonomie :

* **observe** — le modèle analyse et rien d'autre.
* **suggest** — il propose ; chaque action attend une validation humaine.
* **auto** — il exécute, mais uniquement des actions réversibles, explicitement
  autorisées sur cet agent, et dans la limite d'un quota par exécution.

Rien de destructif n'est jamais exécuté sans validation, quel que soit le mode :
la liste blanche est vérifiée côté serveur, pas seulement dans l'invite.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import time
from typing import Any

from .bus import bus
from .collectors.ollama import OllamaClient
from .db import execute, fetch_all, fetch_one
from .scheduler import next_occurrence, validate_cron

log = logging.getLogger("mba.agents")

TICK = 60.0


# --------------------------------------------------------------- catalogue
# `auto` = exécutable sans validation humaine quand l'agent est en mode auto.
# Tout ce qui interrompt un service ou détruit une donnée reste à false.
ACTION_CATALOG: dict[str, dict[str, Any]] = {
    "upgrade_host": {
        "label": "Mettre à jour les paquets",
        "auto": True,
        "severity": "medium",
        "params": [],
        "help": "apt/dnf upgrade sur l'hôte visé.",
    },
    "restart_service": {
        "label": "Redémarrer un service systemd",
        "auto": True,
        "severity": "medium",
        "params": ["service"],
        "help": "Relance un service en échec.",
    },
    "restart_container": {
        "label": "Redémarrer un conteneur",
        "auto": True,
        "severity": "medium",
        "params": ["container"],
        "help": "Relance un conteneur arrêté ou en boucle.",
    },
    "pull_image": {
        "label": "Récupérer la dernière image",
        "auto": True,
        "severity": "low",
        "params": ["container"],
        "help": "docker pull, sans recréer le conteneur.",
    },
    "update_stack": {
        "label": "Mettre à jour une pile compose",
        "auto": False,
        "severity": "high",
        "params": ["project"],
        "help": "compose pull + up -d : recrée les conteneurs de la pile.",
    },
    "prune_docker": {
        "label": "Purger conteneurs arrêtés et cache",
        "auto": True,
        "severity": "low",
        "params": [],
        "help": "Ne touche ni aux volumes ni aux images taguées.",
    },
    "reboot_host": {
        "label": "Redémarrer la machine",
        "auto": False,
        "severity": "critical",
        "params": [],
        "help": "Interrompt tous les services hébergés.",
    },
    "backup_guest": {
        "label": "Lancer une sauvegarde Proxmox",
        "auto": True,
        "severity": "low",
        "params": ["vmid", "storage"],
        "help": "vzdump en mode snapshot.",
    },
}

# Rôles préconfigurés : mission, invite système et actions pertinentes.
ROLES: dict[str, dict[str, Any]] = {
    "ops": {
        "label": "Exploitation",
        "description": "Surveille la santé générale et corrige les dérives courantes.",
        "actions": ["restart_service", "restart_container", "prune_docker"],
        "prompt": (
            "Tu es ingénieur d'exploitation pour une infrastructure personnelle. "
            "Tu identifies les anomalies opérationnelles : services en échec, conteneurs "
            "arrêtés, saturation disque ou mémoire, machines injoignables. "
            "Tu privilégies toujours l'action la plus réversible, et tu ne proposes rien "
            "quand la situation est saine."
        ),
    },
    "updates": {
        "label": "Mises à jour",
        "description": "Maintient le parc à jour sans casser la production.",
        "actions": ["upgrade_host", "pull_image", "update_stack"],
        "prompt": (
            "Tu es responsable du maintien en condition opérationnelle. "
            "Tu traites les correctifs en attente en priorisant ceux de sécurité, et les "
            "images de conteneurs obsolètes. Tu échelonnes : jamais toutes les machines "
            "d'un coup, et jamais un hôte déjà en difficulté."
        ),
    },
    "security": {
        "label": "Sécurité",
        "description": "Analyse les constats de sécurité et propose les remédiations.",
        "actions": ["upgrade_host", "restart_service"],
        "prompt": (
            "Tu es analyste sécurité. Tu examines les constats ouverts et tu les hiérarchises "
            "par risque réel dans le contexte d'un réseau domestique, pas par sévérité "
            "théorique. Pour ce qui n'est pas automatisable (durcissement SSH, pare-feu), "
            "tu décris précisément la manipulation à faire à la main."
        ),
    },
    "backup": {
        "label": "Sauvegardes",
        "description": "Traque les écarts de couverture et relance les sauvegardes.",
        "actions": ["backup_guest"],
        "prompt": (
            "Tu es responsable de la protection des données. Tu vérifies que chaque machine "
            "et chaque VM dispose d'une sauvegarde récente, tu signales les copies périmées "
            "et l'absence de copie hors site. Tu proposes de relancer les sauvegardes "
            "manquantes."
        ),
    },
    "custom": {
        "label": "Sur mesure",
        "description": "Mission libre, définie par ton invite système.",
        "actions": [],
        "prompt": "",
    },
}

# Contrat de sortie imposé au modèle.
OUTPUT_CONTRACT = """
Réponds UNIQUEMENT avec un objet JSON valide, sans texte autour, de cette forme :

{
  "summary": "une phrase de synthèse en français",
  "analysis": "ton raisonnement en français, 3 à 8 phrases, factuel",
  "actions": [
    {
      "action": "<un identifiant de la liste des actions autorisées>",
      "host": "<nom exact d'un hôte du contexte>",
      "params": {},
      "reason": "pourquoi cette action, en une phrase",
      "severity": "low|medium|high|critical"
    }
  ]
}

Règles :
- N'invente aucun nom d'hôte, de service ou de conteneur : utilise uniquement ceux du contexte.
- Si rien ne justifie d'agir, renvoie "actions": [].
- Une action par problème identifié, pas de doublon.
- Ne propose jamais d'action sur un hôte hors ligne, sauf pour le signaler dans l'analyse.
"""


class AgentError(RuntimeError):
    pass


# ------------------------------------------------------------------ contexte
async def scope_hosts(agent: dict) -> list[dict]:
    kind, value = agent["scope_kind"], agent.get("scope_value")
    if kind == "host":
        row = await fetch_one("SELECT * FROM hosts WHERE id = :id AND enabled",
                              {"id": int(value)} if value else {"id": -1})
        return [row] if row else []
    if kind == "tag":
        return await fetch_all(
            "SELECT * FROM hosts WHERE enabled AND :t = ANY(tags) ORDER BY name", {"t": value}
        )
    if kind == "kind":
        return await fetch_all(
            "SELECT * FROM hosts WHERE enabled AND kind = :k ORDER BY name", {"k": value}
        )
    return await fetch_all("SELECT * FROM hosts WHERE enabled ORDER BY name")


async def build_context(agent: dict) -> dict[str, Any]:
    """État condensé de l'infra : assez pour décider, assez court pour tenir
    dans une fenêtre de contexte modeste."""
    hosts = await scope_hosts(agent)
    host_ids = [h["id"] for h in hosts]
    live = bus.latest("metrics.")

    machines = []
    for host in hosts:
        sample = live.get(f"metrics.{host['id']}", {})
        meta = host.get("meta") or {}
        machines.append({
            "name": host["name"],
            "type": host["kind"],
            "statut": host["status"],
            "os": meta.get("os"),
            "cpu_pct": round(sample.get("cpu.usage", 0), 1) or None,
            "ram_pct": round(sample.get("mem.percent", 0), 1) or None,
            "disque_pct": round(sample.get("disk.percent", 0), 1) or None,
            "temp_c": round(sample.get("temp.cpu", 0), 1) or None,
            "uptime_j": round((sample.get("uptime") or 0) / 86400, 1) or None,
            "maj_en_attente": meta.get("updates", 0),
            "maj_securite": meta.get("security_updates", 0),
            "redemarrage_requis": bool(meta.get("reboot_required")),
            "services_en_echec": (meta.get("services_failed") or [])[:5],
            "etiquettes": host.get("tags") or [],
        })

    containers = await fetch_all(
        """SELECT c.name, c.state, c.image, c.project, h.name AS host
           FROM containers c JOIN hosts h ON h.id = c.host_id
           WHERE c.kind = 'docker' AND (c.state <> 'running' OR c.image LIKE '%:latest')
             AND (:empty OR c.host_id = ANY(CAST(:ids AS integer[])))
           ORDER BY (c.state <> 'running') DESC LIMIT 25""",
        {"ids": host_ids or [0], "empty": not host_ids},
    )

    findings = await fetch_all(
        """SELECT f.code, f.severity, f.title, f.remediation, h.name AS host
           FROM security_findings f LEFT JOIN hosts h ON h.id = f.host_id
           WHERE f.resolved_at IS NULL AND NOT f.muted
             AND (f.host_id IS NULL OR :empty OR f.host_id = ANY(CAST(:ids AS integer[])))
           ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1
                                    WHEN 'medium' THEN 2 ELSE 3 END
           LIMIT 25""",
        {"ids": host_ids or [0], "empty": not host_ids},
    )

    services = await fetch_all(
        "SELECT name, url, status, last_latency_ms FROM services "
        "WHERE enabled AND status = 'down' LIMIT 15"
    )

    backup = {}
    if agent["role"] in ("backup", "custom", "ops"):
        try:
            from .protection import overview as protection_overview

            data = await protection_overview()
            backup = {
                "couverture_pct": data["summary"]["coverage"],
                "non_sauvegardes": [g["name"] for g in data["gaps"][:10]],
                "risques": [r["title"] for r in data["risks"][:8]],
            }
        except Exception as exc:  # noqa: BLE001
            log.debug("Contexte sauvegardes indisponible : %s", exc)

    return {
        "date": dt.datetime.now(dt.timezone.utc).isoformat(timespec="minutes"),
        "machines": machines,
        "conteneurs_a_surveiller": containers,
        "constats_securite": findings,
        "services_web_en_panne": services,
        "sauvegardes": backup,
    }


# ------------------------------------------------------------------ exécution
def _catalog_for(agent: dict) -> dict[str, dict]:
    allowed = set(agent.get("allowed_actions") or [])
    return {name: spec for name, spec in ACTION_CATALOG.items() if name in allowed}


def build_prompt(agent: dict, context: dict) -> tuple[str, str]:
    catalog = _catalog_for(agent)
    role = ROLES.get(agent["role"], ROLES["custom"])
    base = (agent.get("system_prompt") or "").strip() or role["prompt"]

    actions_doc = "\n".join(
        f"- {name} : {spec['label']}. {spec['help']}"
        + (f" Paramètres requis : {', '.join(spec['params'])}." if spec["params"] else "")
        for name, spec in catalog.items()
    ) or "- (aucune action autorisée : contente-toi d'analyser)"

    system = (
        f"{base}\n\n"
        "Tu opères via MyBeautifulAdmin, une console d'administration. "
        "Tu es factuel, concis, et tu écris en français.\n\n"
        f"Actions que tu peux proposer :\n{actions_doc}\n"
        f"{OUTPUT_CONTRACT}"
    )
    user = (
        "Voici l'état actuel de l'infrastructure :\n\n"
        f"{json.dumps(context, ensure_ascii=False, indent=1, default=str)}\n\n"
        "Analyse cet état et propose les actions nécessaires."
    )
    return system, user


def parse_response(raw: str) -> dict[str, Any]:
    """Extrait le JSON même si le modèle l'a entouré de texte ou de balises."""
    text = raw.strip()
    if "```" in text:
        chunks = [c for c in text.split("```") if "{" in c]
        if chunks:
            text = chunks[0].removeprefix("json").strip()
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1:
        raise AgentError("Le modèle n'a pas renvoyé de JSON exploitable")
    try:
        data = json.loads(text[start:end + 1])
    except json.JSONDecodeError as exc:
        raise AgentError(f"JSON invalide : {exc}") from exc
    if not isinstance(data, dict):
        raise AgentError("Le modèle a renvoyé autre chose qu'un objet")
    return data


async def _call_model(agent: dict, system: str, user: str) -> tuple[str, dict]:
    endpoint = await fetch_one("SELECT * FROM ai_endpoints WHERE id = :id",
                               {"id": agent["endpoint_id"]})
    if not endpoint:
        raise AgentError("Aucun endpoint IA associé à cet agent")

    client = OllamaClient(endpoint["url"], timeout=300.0)
    chunks: list[str] = []
    stats: dict[str, Any] = {}
    try:
        async for part in client.chat(
            agent["model"],
            [{"role": "system", "content": system}, {"role": "user", "content": user}],
            {"temperature": 0.2},
        ):
            if part.get("message", {}).get("content"):
                chunks.append(part["message"]["content"])
            if part.get("done"):
                stats = {
                    "tokens": part.get("eval_count"),
                    "duration_s": round((part.get("total_duration") or 0) / 1e9, 1),
                }
    except Exception as exc:  # noqa: BLE001
        raise AgentError(f"Endpoint IA injoignable : {str(exc)[:200]}") from exc
    return "".join(chunks), stats


async def _record_proposals(agent: dict, run_id: int, actions: list[dict],
                            hosts: list[dict]) -> list[dict]:
    """Valide chaque action proposée contre la liste blanche avant de la stocker."""
    catalog = _catalog_for(agent)
    by_name = {h["name"].lower(): h for h in hosts}
    stored: list[dict] = []

    for raw in actions[: max(1, agent.get("max_actions") or 3)]:
        if not isinstance(raw, dict):
            continue
        name = str(raw.get("action") or "").strip()
        spec = catalog.get(name)
        if not spec:
            # Le modèle a proposé une action non autorisée : on la trace sans l'offrir.
            log.info("Agent %s : action « %s » écartée (hors liste blanche)", agent["name"], name)
            continue

        host = by_name.get(str(raw.get("host") or "").strip().lower())
        if not host:
            continue

        params = raw.get("params") if isinstance(raw.get("params"), dict) else {}
        missing = [p for p in spec["params"] if not params.get(p)]
        if missing:
            log.info("Agent %s : « %s » ignorée, paramètres manquants %s",
                     agent["name"], name, missing)
            continue

        proposal_id = await execute(
            """INSERT INTO agent_proposals (run_id, agent_id, action, host_id, params, reason, severity)
               VALUES (:r, :a, :act, :h, CAST(:p AS jsonb), :reason, :sev) RETURNING id""",
            {"r": run_id, "a": agent["id"], "act": name, "h": host["id"],
             "p": json.dumps(params, default=str),
             "reason": str(raw.get("reason") or "")[:500],
             "sev": raw.get("severity") if raw.get("severity") in
                    ("low", "medium", "high", "critical") else spec["severity"]},
        )
        stored.append({"id": proposal_id, "action": name, "host": host, "params": params,
                       "spec": spec})
    return stored


async def execute_proposal(proposal_id: int, username: str) -> dict[str, Any]:
    """Exécute une proposition validée. Point de passage unique de toute action."""
    from . import actions as act

    proposal = await fetch_one(
        "SELECT p.*, h.* , p.id AS proposal_id, p.action AS proposal_action, p.params AS proposal_params "
        "FROM agent_proposals p JOIN hosts h ON h.id = p.host_id WHERE p.id = :id",
        {"id": proposal_id},
    )
    if not proposal:
        raise AgentError("Proposition introuvable")

    name = proposal["proposal_action"]
    spec = ACTION_CATALOG.get(name)
    if not spec:
        raise AgentError(f"Action inconnue : {name}")
    params = proposal["proposal_params"] or {}
    host = {k: proposal[k] for k in ("id", "name", "kind", "address", "port",
                                     "credential_id", "meta") if k in proposal}

    try:
        if name == "upgrade_host":
            result = await act.upgrade_host(host, f"agent:{username}")
        elif name == "restart_service":
            result = await act.service_action(host, params["service"], "restart", f"agent:{username}")
        elif name == "restart_container":
            result = await act.container_action(host, params["container"], "restart", f"agent:{username}")
        elif name == "pull_image":
            from .collectors.docker import pull_image

            row = await fetch_one(
                "SELECT image FROM containers WHERE host_id=:h AND (name=:c OR ext_id=:c)",
                {"h": host["id"], "c": params["container"]},
            )
            result = await pull_image(host, (row or {}).get("image", ""))
        elif name == "update_stack":
            from .collectors.docker import compose_update

            rows = await fetch_all(
                "SELECT labels FROM containers WHERE host_id=:h AND project=:p LIMIT 5",
                {"h": host["id"], "p": params["project"]},
            )
            workdir = next((r["labels"].get("com.docker.compose.project.working_dir")
                            for r in rows if (r["labels"] or {}).get(
                                "com.docker.compose.project.working_dir")), None)
            result = await compose_update(host, params["project"], workdir)
        elif name == "prune_docker":
            from .collectors.docker import prune

            reclaimed = 0
            for target in ("containers", "build_cache"):
                outcome = await prune(host, target)
                reclaimed += outcome.get("reclaimed") or 0
            result = {"reclaimed": reclaimed}
        elif name == "reboot_host":
            result = await act.power_action(host, "reboot", f"agent:{username}")
        elif name == "backup_guest":
            from .collectors.proxmox import client_for_host

            client = await client_for_host(host)
            try:
                nodes = (host.get("meta") or {}).get("nodes") or []
                result = await client.backup(nodes[0], int(params["vmid"]), params["storage"])
            finally:
                await client.close()
        else:
            raise AgentError(f"Action non implémentée : {name}")
    except Exception as exc:  # noqa: BLE001
        await execute(
            "UPDATE agent_proposals SET state='failed', result=:r, decided_by=:u, decided_at=now() "
            "WHERE id=:id",
            {"r": str(exc)[:2000], "u": username, "id": proposal_id},
        )
        raise AgentError(str(exc)[:300]) from exc

    summary = json.dumps(result, default=str)[:2000]
    await execute(
        "UPDATE agent_proposals SET state='executed', result=:r, decided_by=:u, decided_at=now() "
        "WHERE id=:id",
        {"r": summary, "u": username, "id": proposal_id},
    )
    from .poller import log_event

    await log_event(host["id"], "info", "agent",
                    f"Action « {spec['label']} » exécutée sur {host['name']} ({username})")
    return {"ok": True, "result": result}


# ------------------------------------------------------------------- cycle
async def run_agent(agent: dict, trigger: str = "manual", username: str = "agent") -> dict[str, Any]:
    started = time.time()
    await execute("UPDATE agents SET running = true WHERE id = :id", {"id": agent["id"]})
    run_id = await execute(
        "INSERT INTO agent_runs (agent_id, trigger, status) VALUES (:a, :t, 'running') RETURNING id",
        {"a": agent["id"], "t": trigger},
    )
    bus.publish("agent", {"id": agent["id"], "name": agent["name"], "state": "running"})

    try:
        hosts = await scope_hosts(agent)
        if not hosts:
            raise AgentError("Aucune machine dans le périmètre de cet agent")

        context = await build_context(agent)
        system, user = build_prompt(agent, context)
        raw, stats = await _call_model(agent, system, user)
        parsed = parse_response(raw)

        proposals = await _record_proposals(agent, run_id, parsed.get("actions") or [], hosts)

        executed, failed = 0, 0
        if agent["mode"] == "auto":
            for proposal in proposals:
                # Double garde : la liste blanche de l'agent ET le catalogue.
                if not proposal["spec"]["auto"]:
                    continue
                try:
                    await execute_proposal(proposal["id"], f"auto:{agent['name']}")
                    executed += 1
                except AgentError:
                    failed += 1
        elif agent["mode"] == "observe":
            # En observation, on ne laisse même pas les propositions en attente.
            await execute(
                "UPDATE agent_proposals SET state='observed' WHERE run_id = :r", {"r": run_id}
            )

        status = "failed" if failed and not executed else "success"
        await execute(
            """UPDATE agent_runs SET status=:s, summary=:sum, analysis=:an,
                   context=CAST(:ctx AS jsonb), duration_s=:d, ended_at=now() WHERE id=:id""",
            {"s": status, "sum": str(parsed.get("summary") or "")[:1000],
             "an": str(parsed.get("analysis") or "")[:8000],
             "ctx": json.dumps(context, default=str)[:200000],
             "d": round(time.time() - started, 1), "id": run_id},
        )
        outcome = {
            "run_id": run_id,
            "status": status,
            "summary": parsed.get("summary"),
            "analysis": parsed.get("analysis"),
            "proposals": len(proposals),
            "executed": executed,
            "failed": failed,
            "tokens": stats.get("tokens"),
        }
    except Exception as exc:  # noqa: BLE001
        await execute(
            "UPDATE agent_runs SET status='failed', error=:e, duration_s=:d, ended_at=now() "
            "WHERE id=:id",
            {"e": str(exc)[:2000], "d": round(time.time() - started, 1), "id": run_id},
        )
        outcome = {"run_id": run_id, "status": "failed", "error": str(exc)[:300]}
        log.warning("Agent %s en échec : %s", agent["name"], exc)
    finally:
        next_run = None
        if agent.get("cron"):
            try:
                next_run = next_occurrence(agent["cron"])
            except Exception:  # noqa: BLE001
                next_run = None
        await execute(
            "UPDATE agents SET running=false, last_run=now(), last_status=:s, next_run=:n "
            "WHERE id=:id",
            {"s": outcome["status"], "n": next_run, "id": agent["id"]},
        )
        bus.publish("agent", {"id": agent["id"], "name": agent["name"], "state": "done",
                              "status": outcome["status"]})
    return outcome


async def run_scheduler_loop() -> None:
    await asyncio.sleep(20)
    try:
        pending = await fetch_all(
            "SELECT id, cron FROM agents WHERE enabled AND cron IS NOT NULL AND next_run IS NULL"
        )
        for row in pending:
            try:
                validate_cron(row["cron"])
                await execute("UPDATE agents SET next_run=:n WHERE id=:id",
                              {"n": next_occurrence(row["cron"]), "id": row["id"]})
            except ValueError:
                continue
        await execute("UPDATE agents SET running = false WHERE running")
    except Exception as exc:  # noqa: BLE001
        log.warning("Amorçage des agents : %s", exc)

    while True:
        try:
            due = await fetch_all(
                "SELECT * FROM agents WHERE enabled AND NOT running "
                "AND cron IS NOT NULL AND next_run <= now()"
            )
            for agent in due:
                asyncio.create_task(run_agent(agent, trigger="planifié"))
        except Exception as exc:  # noqa: BLE001
            log.warning("Boucle des agents : %s", exc)
        await asyncio.sleep(TICK)
