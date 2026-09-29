"""Live feed.

The snapshot is serialized once per tick and the same bytes go to every client;
fan-out, not computation, is what this machine spends its capacity on.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..config import Settings, settings
from ..processor import Processor

log = logging.getLogger("bus.ws")

router = APIRouter()


class Hub:
    def __init__(self, processor: Processor, cfg: Settings | None = None):
        self.p = processor
        self.cfg = cfg or settings
        self.clients: set[WebSocket] = set()

    async def register(self, ws: WebSocket) -> None:
        await ws.accept()
        self.clients.add(ws)
        await ws.send_text(json.dumps(self.p.snapshot()))

    def unregister(self, ws: WebSocket) -> None:
        self.clients.discard(ws)

    async def run(self) -> None:
        interval = 1.0 / max(0.1, self.cfg.broadcast_hz)
        while True:
            await asyncio.sleep(interval)
            if not self.clients:
                continue
            frame = json.dumps(self.p.snapshot(time.time()))
            dead = []
            for ws in list(self.clients):
                try:
                    await ws.send_text(frame)
                except Exception:
                    dead.append(ws)
            for ws in dead:
                self.unregister(ws)


@router.websocket("/ws/live")
async def live(ws: WebSocket) -> None:
    hub: Hub = ws.app.state.hub
    await hub.register(ws)
    try:
        while True:
            # Clients send pings to keep intermediaries from closing an idle
            # socket; nothing they say changes server state.
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    except Exception:
        log.debug("websocket closed unexpectedly", exc_info=True)
    finally:
        hub.unregister(ws)
