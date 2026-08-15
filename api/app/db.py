from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, async_sessionmaker, create_async_engine

from .config import settings

engine = create_async_engine(
    settings.database_url,
    pool_size=10,
    max_overflow=20,
    pool_pre_ping=True,
    echo=False,
)

SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


@asynccontextmanager
async def connection() -> AsyncIterator[AsyncConnection]:
    async with engine.begin() as conn:
        yield conn


async def fetch_all(sql: str, params: dict[str, Any] | None = None) -> list[dict]:
    async with engine.connect() as conn:
        res = await conn.execute(text(sql), params or {})
        return [dict(r) for r in res.mappings().all()]


async def fetch_one(sql: str, params: dict[str, Any] | None = None) -> dict | None:
    rows = await fetch_all(sql, params)
    return rows[0] if rows else None


async def fetch_val(sql: str, params: dict[str, Any] | None = None) -> Any:
    async with engine.connect() as conn:
        res = await conn.execute(text(sql), params or {})
        row = res.first()
        return row[0] if row else None


async def execute(sql: str, params: dict[str, Any] | None = None) -> Any:
    async with engine.begin() as conn:
        res = await conn.execute(text(sql), params or {})
        try:
            row = res.first()
            return row[0] if row else None
        except Exception:  # pas de RETURNING
            return None


async def execute_many(sql: str, rows: list[dict]) -> None:
    if not rows:
        return
    async with engine.begin() as conn:
        await conn.execute(text(sql), rows)


async def wait_for_db(timeout: float = 60.0) -> None:
    import asyncio

    loop = asyncio.get_event_loop()
    deadline = loop.time() + timeout
    last: Exception | None = None
    while loop.time() < deadline:
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001
            last = exc
            await asyncio.sleep(1.0)
    raise RuntimeError(f"Base de données injoignable: {last}")
