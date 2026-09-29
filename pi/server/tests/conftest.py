from __future__ import annotations

import itertools

import pytest

from app.config import REPO_ROOT, Settings
from app.db import Database
from app.planner import Planner
from app.processor import Processor
from app.static_data import StaticData


@pytest.fixture
def cfg(tmp_path) -> Settings:
    s = Settings()
    s.data_dir = REPO_ROOT / "data"
    s.db_path = tmp_path / "test.db"
    s.push_enabled = False
    s.mqtt_enabled = False
    return s


@pytest.fixture
def data(cfg) -> StaticData:
    return StaticData(cfg)


@pytest.fixture
def db(cfg) -> Database:
    d = Database(cfg.db_path, flush_sec=3600)
    d.connect()
    yield d
    d.close()


@pytest.fixture
def processor(data, db, cfg) -> Processor:
    return Processor(data, db, cfg=cfg)


@pytest.fixture
def planner(processor, cfg) -> Planner:
    return Planner(processor, cfg=cfg)


_seq = itertools.count(1)


def feed(processor: Processor, bus_id: str, lat: float, lng: float, *, t: float,
         spd: float = 6.0, seq: int | None = None, sats: int = 9, hdop: float = 1.0) -> bool:
    """Publish one fix. seq is auto-assigned from a process-wide counter unless a
    test is specifically exercising sequence handling."""
    payload = {
        "lat": lat,
        "lng": lng,
        "spd": spd,
        "sats": sats,
        "hdop": hdop,
        "t": t,
        "seq": next(_seq) if seq is None else seq,
    }
    return processor.handle_message(bus_id, payload, now=t)
