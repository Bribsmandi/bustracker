"""Application wiring.

The processor and the API share one asyncio process on purpose: live state stays
in memory, so there is no internal queue, cache or IPC to go wrong.

The Pi holds no broker of its own. It opens one outbound connection to the broker
on the public VM — raw fixes come down it, the processed snapshot goes back up it
for the app to subscribe to. The REST API and /ws/live remain for the things
pub/sub is the wrong shape for: config, trip planning and analytics.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import sys
from collections.abc import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .api import rest, ws
from .config import settings
from .db import Database
from .notifier import Notifier
from .planner import Planner
from .processor import Processor
from .static_data import StaticData

log = logging.getLogger("bus")

PRUNE_INTERVAL_SEC = 6 * 3600


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stdout,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


async def _prune_loop(db: Database) -> None:
    while True:
        db.prune_positions(settings.track_retain_days)
        await asyncio.sleep(PRUNE_INTERVAL_SEC)


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    configure_logging()

    data = StaticData()
    log.info(
        "loaded %d stops, %d buses, %d routes (config %s)",
        len(data.stops),
        len(data.buses),
        len(data.routes),
        data.version,
    )

    db = Database(settings.db_path, settings.db_flush_sec)
    db.connect()

    processor = Processor(data, db)
    planner = Planner(processor)
    hub = ws.Hub(processor)
    notifier = Notifier(planner, db)

    app.state.data = data
    app.state.db = db
    app.state.processor = processor
    app.state.planner = planner
    app.state.hub = hub
    app.state.mqtt = None
    app.state.ingest_tokens = rest._load_ingest_tokens(settings.ingest_tokens_path)

    tasks = [
        asyncio.create_task(db.run(), name="db-flush"),
        asyncio.create_task(hub.run(), name="broadcast"),
        asyncio.create_task(notifier.run(), name="notifier"),
        asyncio.create_task(_prune_loop(db), name="prune"),
    ]

    if settings.mqtt_enabled:
        from .mqtt_link import MqttLink

        link = MqttLink(processor, planner)
        app.state.mqtt = link
        await link.start()
        tasks.append(asyncio.create_task(link.run_publisher(), name="live-publish"))

    try:
        yield
    finally:
        if app.state.mqtt is not None:
            await app.state.mqtt.stop()
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        db.close()
        log.info("shutdown complete")


def create_app() -> FastAPI:
    app = FastAPI(title="Campus Bus Tracker", version="2.0", lifespan=lifespan)
    # The app is a native client, not a browser origin, but the tracker also
    # builds for web and is served from elsewhere.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["GET", "POST", "DELETE"],
        allow_headers=["*"],
    )
    app.include_router(rest.router)
    app.include_router(ws.router)
    return app


app = create_app()
