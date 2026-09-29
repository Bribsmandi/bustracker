"""Public REST API.

The live map does not come through here — the app subscribes to the broker for
that. This serves what pub/sub is the wrong shape for: static config, trip
planning, and analytics. Everything is read-only apart from push subscriptions
and the test-injection route.
"""
from __future__ import annotations

import hmac
import json
import logging
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Header, Request
from pydantic import BaseModel, Field

log = logging.getLogger("bus.api")

router = APIRouter()


class SubscriptionIn(BaseModel):
    device_token: str = Field(min_length=8, max_length=512)
    stop_id: str = Field(min_length=1, max_length=64)
    route_id: str | None = Field(default=None, max_length=64)
    lead_minutes: int = Field(default=5, ge=1, le=60)


class PositionIn(BaseModel):
    """A single fix, in the same shape the relay republishes onto MQTT."""

    lat: float
    lng: float
    seq: int | None = None
    t: float | None = None
    spd: float | None = None
    hdg: float | None = None
    sats: int | None = None
    hdop: float | None = None


def _load_ingest_tokens(path: Path) -> dict[str, str]:
    try:
        with open(path) as f:
            return {str(k): str(v) for k, v in json.load(f).items()}
    except FileNotFoundError:
        return {}
    except Exception:
        log.exception("could not read ingest tokens from %s", path)
        return {}


@router.get("/health")
async def health(request: Request) -> dict:
    app = request.app
    now = time.time()
    return {
        "ok": True,
        "ts": int(now),
        "buses_online": app.state.processor.live.online_count(now),
        "buses_total": len(app.state.processor.live.buses),
        "ws_clients": len(app.state.hub.clients),
        "mqtt_connected": bool(app.state.mqtt and app.state.mqtt.connected),
        "mqtt_published": app.state.mqtt.published if app.state.mqtt else 0,
        "config_version": app.state.data.version,
    }


@router.get("/config")
async def config(request: Request) -> dict:
    return request.app.state.data.config_payload()


@router.get("/buses")
async def buses(request: Request) -> dict:
    return request.app.state.processor.snapshot()


@router.get("/stops")
async def stops(request: Request) -> dict:
    return {"stops": request.app.state.data.config_payload()["stops"]}


@router.get("/stops/{stop_id}/arrivals")
async def arrivals(stop_id: str, request: Request) -> dict:
    result = request.app.state.planner.arrivals(stop_id)
    if result.get("error"):
        raise HTTPException(404, result["error"])
    return result


@router.get("/trip")
async def trip(request: Request, from_: str = "", to: str = "") -> dict:
    # `from` is a Python keyword, so the query parameter is read directly.
    src = request.query_params.get("from", from_)
    dst = request.query_params.get("to", to)
    if not src or not dst:
        raise HTTPException(400, "from and to are required")
    result = request.app.state.planner.plan(src, dst)
    if result.get("error"):
        raise HTTPException(400, result["error"])
    return result


@router.get("/departures")
async def departures(request: Request, limit: int = 20) -> dict:
    return {"departures": request.app.state.planner.upcoming_departures(min(limit, 100))}


@router.post("/subscriptions", status_code=201)
async def add_subscription(body: SubscriptionIn, request: Request) -> dict:
    data = request.app.state.data
    if body.stop_id not in data.stops:
        raise HTTPException(400, "unknown stop")
    if body.route_id is not None and body.route_id not in data.routes:
        raise HTTPException(400, "unknown route")
    sub_id = request.app.state.db.add_subscription(
        body.device_token, body.stop_id, body.route_id, body.lead_minutes
    )
    return {"id": sub_id}


@router.delete("/subscriptions/{sub_id}")
async def remove_subscription(
    sub_id: int, request: Request, x_device_token: str = Header(default="")
) -> dict:
    if not x_device_token:
        raise HTTPException(401, "X-Device-Token required")
    if not request.app.state.db.remove_subscription(sub_id, x_device_token):
        raise HTTPException(404, "no such subscription for this device")
    return {"ok": True}


@router.get("/analytics/buses")
async def analytics_buses(request: Request, from_ts: int | None = None, to_ts: int | None = None) -> dict:
    now = int(time.time())
    start = from_ts if from_ts is not None else now - 7 * 86400
    end = to_ts if to_ts is not None else now
    return {"from": start, "to": end, "buses": request.app.state.db.bus_analytics(start, end)}


@router.get("/analytics/stops/{stop_id}")
async def analytics_stop(stop_id: str, request: Request) -> dict:
    if stop_id not in request.app.state.data.stops:
        raise HTTPException(404, "unknown stop")
    return request.app.state.db.stop_analytics(stop_id)


@router.get("/analytics/trips")
async def analytics_trips(request: Request, bus_id: str | None = None, limit: int = 100) -> dict:
    return {"trips": request.app.state.db.recent_trips(bus_id, min(limit, 500))}


@router.post("/ingest/{bus_id}")
async def ingest(
    bus_id: str, body: PositionIn, request: Request, authorization: str = Header(default="")
) -> dict:
    """Direct injection, bypassing the relay and the broker.

    The buses do not use this: they POST to relay.py, which verifies the device
    signature and republishes to MQTT. This exists so the pipeline can be driven
    from a laptop or a test script without a broker running.
    """
    app = request.app
    tokens = app.state.ingest_tokens
    expected = tokens.get(bus_id)
    supplied = authorization.removeprefix("Bearer ").strip()
    if not expected or not hmac.compare_digest(supplied, expected):
        raise HTTPException(403, "bad credentials")
    ok = app.state.processor.handle_message(bus_id, body.model_dump(exclude_none=True))
    return {"ok": ok}
