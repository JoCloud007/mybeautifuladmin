from __future__ import annotations

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .config import settings
from .db import execute, fetch_one, wait_for_db
from .agents import run_scheduler_loop as run_agents
from .audit import run_periodic as run_security_scan
from .migrations import apply as apply_migrations
from .poller import check_services, evaluate_alerts, poll_ai_endpoints, supervisor
from .scheduler import run_scheduler
from .routers import (agents, ai, auth, discovery, home, hosts, inventory, ipmi, monitoring,
                      protection, proxmox, scheduler, security, services, stream, synology,
                      terminal)
from .security import hash_password

logging.basicConfig(
    level=getattr(logging, settings.log_level.upper(), logging.INFO),
    format="%(asctime)s %(levelname)-7s %(name)-16s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("mba")

# Les collecteurs font des dizaines de requêtes HTTP par cycle : au niveau INFO,
# httpx noierait le journal applicatif.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

BACKGROUND: list[asyncio.Task] = []


async def bootstrap_admin() -> None:
    existing = await fetch_one("SELECT id FROM users LIMIT 1")
    if existing:
        return
    await execute(
        "INSERT INTO users (username, password_hash, role) VALUES (:u, :p, 'admin')",
        {"u": settings.admin_user, "p": hash_password(settings.admin_password)},
    )
    log.warning("Compte admin « %s » créé — pense à changer le mot de passe.", settings.admin_user)


async def register_local_docker() -> None:
    """Si le socket Docker est monté, on s'auto-enregistre comme hôte."""
    from .collectors.docker import socket_available

    if not socket_available():
        return
    existing = await fetch_one("SELECT id FROM hosts WHERE address = 'local' AND kind = 'docker'")
    if existing:
        return
    await execute(
        "INSERT INTO hosts (name, kind, address, port, meta) "
        "VALUES ('Docker local', 'docker', 'local', 0, CAST('{\"builtin\": true}' AS jsonb))"
    )
    log.info("Hôte « Docker local » enregistré depuis le socket monté.")


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Démarrage de MyBeautifulAdmin…")
    await wait_for_db()
    await apply_migrations()
    await bootstrap_admin()
    await register_local_docker()
    await supervisor.start()
    BACKGROUND.extend([
        asyncio.create_task(check_services(), name="services"),
        asyncio.create_task(poll_ai_endpoints(), name="ai"),
        asyncio.create_task(evaluate_alerts(), name="alerts"),
        asyncio.create_task(run_scheduler(), name="scheduler"),
        asyncio.create_task(run_security_scan(), name="security"),
        asyncio.create_task(run_agents(), name="agents"),
    ])
    log.info("Prêt — collecte toutes les %ss", settings.poll_interval)
    try:
        yield
    finally:
        log.info("Arrêt…")
        for task in BACKGROUND:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        await supervisor.stop()


app = FastAPI(
    title="MyBeautifulAdmin",
    description="Monitoring et administration d'infrastructure",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

for module in (auth, hosts, inventory, monitoring, services, ai, agents, discovery,
               synology, proxmox, ipmi, protection, home, security, scheduler,
               terminal, stream):
    app.include_router(module.router)


@app.get("/health", tags=["système"])
async def health() -> dict:
    try:
        await fetch_one("SELECT 1 AS ok")
        db_ok = True
    except Exception:  # noqa: BLE001
        db_ok = False
    return {
        "status": "ok" if db_ok else "degraded",
        "database": db_ok,
        "workers": len(supervisor.workers),
    }


@app.exception_handler(Exception)
async def unhandled(request, exc: Exception) -> JSONResponse:
    log.exception("Erreur non gérée sur %s", request.url.path)
    return JSONResponse(status_code=500, content={"detail": f"Erreur interne : {exc}"})
