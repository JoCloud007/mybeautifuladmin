from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from pydantic import BaseModel, Field, HttpUrl

from ..db import execute, fetch_all, fetch_one
from ..security import current_user

router = APIRouter(prefix="/services", tags=["services"])


class ServiceIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    url: HttpUrl
    host_id: int | None = None
    method: str = "GET"
    expect_status: int = 200
    expect_body: str | None = None
    interval_s: int = Field(30, ge=5, le=3600)
    icon: str | None = None
    group_name: str | None = None
    enabled: bool = True


class ServicePatch(BaseModel):
    name: str | None = None
    url: HttpUrl | None = None
    host_id: int | None = None
    method: str | None = None
    expect_status: int | None = None
    expect_body: str | None = None
    interval_s: int | None = None
    icon: str | None = None
    group_name: str | None = None
    enabled: bool | None = None


@router.get("")
async def list_services(user: dict = Depends(current_user)) -> list[dict]:
    services = await fetch_all(
        "SELECT s.*, h.name AS host_name FROM services s LEFT JOIN hosts h ON h.id = s.host_id "
        "ORDER BY coalesce(s.group_name,'~'), s.name"
    )
    # Disponibilité sur 24 h + sparkline de latence, en une passe.
    stats = await fetch_all(
        """
        SELECT service_id,
               100.0 * count(*) FILTER (WHERE ok) / NULLIF(count(*), 0) AS uptime_24h,
               avg(latency_ms) FILTER (WHERE ok) AS avg_latency
        FROM service_checks WHERE time > now() - interval '24 hours'
        GROUP BY service_id
        """
    )
    by_id = {s["service_id"]: s for s in stats}
    for svc in services:
        stat = by_id.get(svc["id"], {})
        # float() explicite : sans lui, un Decimal ressort en chaîne dans le JSON.
        svc["uptime_24h"] = round(float(stat.get("uptime_24h") or 0.0), 2)
        svc["avg_latency"] = round(float(stat.get("avg_latency") or 0.0), 1)
    return services


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_service(payload: ServiceIn, user: dict = Depends(current_user)) -> dict:
    service_id = await execute(
        """INSERT INTO services (name, url, host_id, method, expect_status, expect_body,
                                 interval_s, icon, group_name, enabled)
           VALUES (:name, :url, :host_id, :method, :expect_status, :expect_body,
                   :interval_s, :icon, :group_name, :enabled) RETURNING id""",
        {**payload.model_dump(), "url": str(payload.url)},
    )
    return await fetch_one("SELECT * FROM services WHERE id = :id", {"id": service_id})


@router.patch("/{service_id}")
async def update_service(service_id: int, payload: ServicePatch,
                         user: dict = Depends(current_user)) -> dict:
    fields = payload.model_dump(exclude_unset=True)
    if "url" in fields and fields["url"] is not None:
        fields["url"] = str(fields["url"])
    if fields:
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        await execute(f"UPDATE services SET {sets} WHERE id = :id", {**fields, "id": service_id})
    service = await fetch_one("SELECT * FROM services WHERE id = :id", {"id": service_id})
    if not service:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Service introuvable")
    return service


@router.delete("/{service_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_service(service_id: int, user: dict = Depends(current_user)) -> Response:
    await execute("DELETE FROM services WHERE id = :id", {"id": service_id})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{service_id}/history")
async def service_history(service_id: int, range_: str = Query("24h", alias="range"),
                          user: dict = Depends(current_user)) -> dict:
    windows = {"1h": 3600, "24h": 86400, "7d": 604800, "30d": 2592000}
    window = windows.get(range_)
    if not window:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Plage inconnue")
    bucket = max(60, window // 120)
    rows = await fetch_all(
        """
        SELECT extract(epoch FROM time_bucket(make_interval(secs => :bucket), time)) AS t,
               avg(latency_ms) AS latency,
               100.0 * count(*) FILTER (WHERE ok) / NULLIF(count(*), 0) AS uptime
        FROM service_checks
        WHERE service_id = :id AND time > now() - make_interval(secs => :window)
        GROUP BY t ORDER BY t
        """,
        {"bucket": bucket, "id": service_id, "window": window},
    )
    incidents = await fetch_all(
        "SELECT time, status_code, error FROM service_checks "
        "WHERE service_id = :id AND NOT ok AND time > now() - make_interval(secs => :window) "
        "ORDER BY time DESC LIMIT 50",
        {"id": service_id, "window": window},
    )
    return {
        "points": [{"t": float(r["t"]), "latency": float(r["latency"] or 0),
                    "uptime": float(r["uptime"] or 0)} for r in rows],
        "incidents": incidents,
    }


@router.post("/{service_id}/check")
async def check_now(service_id: int, user: dict = Depends(current_user)) -> dict:
    """Force un contrôle immédiat (le worker reprend ensuite son rythme)."""
    import httpx

    from ..poller import _check_service

    service = await fetch_one("SELECT * FROM services WHERE id = :id", {"id": service_id})
    if not service:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Service introuvable")
    async with httpx.AsyncClient(verify=False, timeout=15.0, follow_redirects=True) as client:
        await _check_service(client, service)
    return await fetch_one("SELECT * FROM services WHERE id = :id", {"id": service_id})
