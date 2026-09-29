"""SQLite storage and the batched writer.

Nothing on the hot path touches the disk. The processor appends operations to an
in-memory queue and a background task commits them in one transaction every few
seconds, which keeps SD/SSD wear negligible and the event loop unblocked.

Bus and stop ids are TEXT, matching data/buses.json ("bus1", "ac_mbh") and
data/stops.json ("mbh", "east_campus").
"""
from __future__ import annotations

import asyncio
import logging
import sqlite3
import statistics
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

log = logging.getLogger("bus.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS trips (
  id             INTEGER PRIMARY KEY,
  bus_id         TEXT    NOT NULL,
  route_id       TEXT,
  origin_id      TEXT,
  destination_id TEXT,
  departed_at    INTEGER NOT NULL,
  arrived_at     INTEGER,
  distance_m     REAL    NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_trips_bus_departed ON trips(bus_id, departed_at DESC);

CREATE TABLE IF NOT EXISTS stop_events (
  id           INTEGER PRIMARY KEY,
  trip_id      INTEGER REFERENCES trips(id),
  bus_id       TEXT    NOT NULL,
  stop_id      TEXT    NOT NULL,
  route_id     TEXT,
  arrived_at   INTEGER NOT NULL,
  departed_at  INTEGER,
  scheduled_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_stop_events_stop_time ON stop_events(stop_id, arrived_at DESC);
CREATE INDEX IF NOT EXISTS idx_stop_events_bus_time  ON stop_events(bus_id, arrived_at DESC);

CREATE TABLE IF NOT EXISTS positions (
  bus_id   TEXT    NOT NULL,
  ts       INTEGER NOT NULL,
  lat      REAL    NOT NULL,
  lng      REAL    NOT NULL,
  speed    REAL,
  route_id TEXT,
  progress REAL,
  PRIMARY KEY (bus_id, ts)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS segment_samples (
  id           INTEGER PRIMARY KEY,
  route_id     TEXT    NOT NULL,
  from_stop    TEXT    NOT NULL,
  to_stop      TEXT    NOT NULL,
  hour_of_week INTEGER NOT NULL,
  duration_s   REAL    NOT NULL,
  at           INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_segment_samples_key
  ON segment_samples(route_id, from_stop, to_stop, hour_of_week, at DESC);

CREATE TABLE IF NOT EXISTS segment_times (
  route_id     TEXT    NOT NULL,
  from_stop    TEXT    NOT NULL,
  to_stop      TEXT    NOT NULL,
  hour_of_week INTEGER NOT NULL,
  n            INTEGER NOT NULL,
  median_s     REAL    NOT NULL,
  PRIMARY KEY (route_id, from_stop, to_stop, hour_of_week)
);

CREATE TABLE IF NOT EXISTS daily_bus_stats (
  day        TEXT    NOT NULL,
  bus_id     TEXT    NOT NULL,
  distance_m REAL    NOT NULL DEFAULT 0,
  active_s   INTEGER NOT NULL DEFAULT 0,
  trips      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, bus_id)
);

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id           INTEGER PRIMARY KEY,
  device_token TEXT    NOT NULL,
  stop_id      TEXT    NOT NULL,
  route_id     TEXT,
  lead_minutes INTEGER NOT NULL DEFAULT 5,
  created_at   INTEGER NOT NULL,
  last_sent_at INTEGER,
  last_key     TEXT,
  UNIQUE (device_token, stop_id, route_id)
);
CREATE INDEX IF NOT EXISTS idx_push_stop ON push_subscriptions(stop_id);
"""

# Enough history to track a shifting median without growing without bound.
SAMPLES_PER_SEGMENT = 50


@dataclass
class Op:
    sql: str
    params: tuple


class Database:
    def __init__(self, path: Path, flush_sec: float = 5.0):
        self.path = path
        self.flush_sec = flush_sec
        self._queue: list[Op] = []
        self._conn: sqlite3.Connection | None = None
        self._lock = asyncio.Lock()
        self._task: asyncio.Task | None = None
        self._segment_cache: dict[tuple[str, str, str, int], tuple[float, int]] = {}

    # ------------------------------------------------------------- lifecycle

    def connect(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(self.path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.executescript(SCHEMA)
        self._conn.commit()
        self._load_segment_cache()

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            raise RuntimeError("database not connected")
        return self._conn

    def close(self) -> None:
        if self._conn is not None:
            self.flush_now()
            self._conn.close()
            self._conn = None

    async def run(self) -> None:
        while True:
            await asyncio.sleep(self.flush_sec)
            try:
                await self.flush()
            except Exception:
                log.exception("flush failed")

    # ---------------------------------------------------------------- writes

    def enqueue(self, sql: str, params: Iterable[Any] = ()) -> None:
        self._queue.append(Op(sql, tuple(params)))

    async def flush(self) -> None:
        async with self._lock:
            if not self._queue:
                return
            batch, self._queue = self._queue, []
            await asyncio.to_thread(self._commit, batch)

    def flush_now(self) -> None:
        batch, self._queue = self._queue, []
        if batch:
            self._commit(batch)

    def _commit(self, batch: list[Op]) -> None:
        cur = self.conn.cursor()
        try:
            cur.execute("BEGIN")
            for op in batch:
                cur.execute(op.sql, op.params)
            cur.execute("COMMIT")
        except Exception:
            cur.execute("ROLLBACK")
            raise

    # ---------------------------------------------- writes needing an id back

    def open_trip(self, bus_id: str, route_id: str | None, origin_id: str | None, ts: float) -> int:
        """Trips are written through immediately: their id keys later rows."""
        cur = self.conn.execute(
            "INSERT INTO trips (bus_id, route_id, origin_id, departed_at) VALUES (?,?,?,?)",
            (bus_id, route_id, origin_id, int(ts)),
        )
        self.conn.commit()
        return int(cur.lastrowid)

    def close_trip(self, trip_id: int, destination_id: str | None, ts: float, distance_m: float) -> None:
        self.enqueue(
            "UPDATE trips SET arrived_at=?, destination_id=COALESCE(?,destination_id), distance_m=? "
            "WHERE id=?",
            (int(ts), destination_id, distance_m, trip_id),
        )

    def abandon_open_trips(self, bus_id: str, destination_id: str | None) -> None:
        """A bus that reached a terminal while offline leaves a trip open. Record
        where it ended up but leave arrived_at null: the leg never completed."""
        self.enqueue(
            "UPDATE trips SET destination_id=COALESCE(destination_id,?) "
            "WHERE bus_id=? AND arrived_at IS NULL",
            (destination_id, bus_id),
        )

    def log_arrival(
        self,
        bus_id: str,
        stop_id: str,
        route_id: str | None,
        trip_id: int | None,
        arrived_at: float,
        scheduled_at: int | None,
    ) -> int:
        cur = self.conn.execute(
            "INSERT INTO stop_events (trip_id, bus_id, stop_id, route_id, arrived_at, scheduled_at) "
            "VALUES (?,?,?,?,?,?)",
            (trip_id, bus_id, stop_id, route_id, int(arrived_at), scheduled_at),
        )
        self.conn.commit()
        return int(cur.lastrowid)

    def log_departure(self, event_id: int, departed_at: float) -> None:
        self.enqueue("UPDATE stop_events SET departed_at=? WHERE id=?", (int(departed_at), event_id))

    def log_position(
        self,
        bus_id: str,
        ts: float,
        lat: float,
        lng: float,
        speed: float,
        route_id: str | None,
        progress: float | None,
    ) -> None:
        self.enqueue(
            "INSERT OR REPLACE INTO positions (bus_id, ts, lat, lng, speed, route_id, progress) "
            "VALUES (?,?,?,?,?,?,?)",
            (bus_id, int(ts), lat, lng, speed, route_id, progress),
        )

    def upsert_daily(self, day: str, bus_id: str, distance_m: float, active_s: float, trips: int) -> None:
        self.enqueue(
            "INSERT INTO daily_bus_stats (day, bus_id, distance_m, active_s, trips) VALUES (?,?,?,?,?) "
            "ON CONFLICT(day, bus_id) DO UPDATE SET distance_m=?, active_s=?, trips=?",
            (day, bus_id, distance_m, int(active_s), trips, distance_m, int(active_s), trips),
        )

    def prune_positions(self, retain_days: int) -> None:
        cutoff = int(time.time() - retain_days * 86400)
        self.enqueue("DELETE FROM positions WHERE ts < ?", (cutoff,))

    # -------------------------------------------------------- segment learning

    def record_segment(
        self, route_id: str, from_stop: str, to_stop: str, hour_of_week: int, duration_s: float
    ) -> None:
        key = (route_id, from_stop, to_stop, hour_of_week)
        self.conn.execute(
            "INSERT INTO segment_samples (route_id, from_stop, to_stop, hour_of_week, duration_s, at) "
            "VALUES (?,?,?,?,?,?)",
            (*key, duration_s, int(time.time())),
        )
        self.conn.execute(
            "DELETE FROM segment_samples WHERE route_id=? AND from_stop=? AND to_stop=? "
            "AND hour_of_week=? AND id NOT IN ("
            "  SELECT id FROM segment_samples WHERE route_id=? AND from_stop=? AND to_stop=? "
            "  AND hour_of_week=? ORDER BY at DESC LIMIT ?)",
            (*key, *key, SAMPLES_PER_SEGMENT),
        )
        rows = self.conn.execute(
            "SELECT duration_s FROM segment_samples WHERE route_id=? AND from_stop=? AND to_stop=? "
            "AND hour_of_week=?",
            key,
        ).fetchall()
        durations = [r["duration_s"] for r in rows]
        median = statistics.median(durations)
        self.conn.execute(
            "INSERT INTO segment_times (route_id, from_stop, to_stop, hour_of_week, n, median_s) "
            "VALUES (?,?,?,?,?,?) ON CONFLICT(route_id, from_stop, to_stop, hour_of_week) "
            "DO UPDATE SET n=?, median_s=?",
            (*key, len(durations), median, len(durations), median),
        )
        self.conn.commit()
        self._segment_cache[key] = (median, len(durations))

    def _load_segment_cache(self) -> None:
        self._segment_cache = {
            (r["route_id"], r["from_stop"], r["to_stop"], r["hour_of_week"]): (r["median_s"], r["n"])
            for r in self.conn.execute(
                "SELECT route_id, from_stop, to_stop, hour_of_week, n, median_s FROM segment_times"
            )
        }

    def median(
        self, route_id: str, from_stop: str, to_stop: str, hour_of_week: int
    ) -> tuple[float, int] | None:
        """SegmentLookup for the ETA stage. Served from memory: it is called for
        every remaining segment of every bus, once per broadcast."""
        return self._segment_cache.get((route_id, from_stop, to_stop, hour_of_week))

    # ----------------------------------------------------------------- reads

    def bus_analytics(self, start: int, end: int) -> list[dict]:
        rows = self.conn.execute(
            "SELECT bus_id, SUM(distance_m) AS distance_m, SUM(active_s) AS active_s, "
            "SUM(trips) AS trips FROM daily_bus_stats WHERE day BETWEEN ? AND ? GROUP BY bus_id",
            (
                time.strftime("%Y-%m-%d", time.localtime(start)),
                time.strftime("%Y-%m-%d", time.localtime(end)),
            ),
        ).fetchall()
        return [dict(r) for r in rows]

    def stop_analytics(self, stop_id: str, limit: int = 200) -> dict:
        rows = self.conn.execute(
            "SELECT bus_id, route_id, arrived_at, departed_at, scheduled_at FROM stop_events "
            "WHERE stop_id=? ORDER BY arrived_at DESC LIMIT ?",
            (stop_id, limit),
        ).fetchall()
        dwells = [
            r["departed_at"] - r["arrived_at"]
            for r in rows
            if r["departed_at"] is not None and r["departed_at"] >= r["arrived_at"]
        ]
        lateness = [
            r["arrived_at"] - r["scheduled_at"] for r in rows if r["scheduled_at"] is not None
        ]
        return {
            "stop_id": stop_id,
            "samples": len(rows),
            "median_dwell_s": statistics.median(dwells) if dwells else None,
            "median_lateness_s": statistics.median(lateness) if lateness else None,
            "recent": [dict(r) for r in rows[:50]],
        }

    def recent_trips(self, bus_id: str | None, limit: int = 100) -> list[dict]:
        if bus_id:
            rows = self.conn.execute(
                "SELECT * FROM trips WHERE bus_id=? ORDER BY departed_at DESC LIMIT ?",
                (bus_id, limit),
            ).fetchall()
        else:
            rows = self.conn.execute(
                "SELECT * FROM trips ORDER BY departed_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(r) for r in rows]

    # --------------------------------------------------------- subscriptions

    def add_subscription(
        self, device_token: str, stop_id: str, route_id: str | None, lead_minutes: int
    ) -> int:
        cur = self.conn.execute(
            "INSERT INTO push_subscriptions (device_token, stop_id, route_id, lead_minutes, created_at) "
            "VALUES (?,?,?,?,?) ON CONFLICT(device_token, stop_id, route_id) "
            "DO UPDATE SET lead_minutes=excluded.lead_minutes",
            (device_token, stop_id, route_id, lead_minutes, int(time.time())),
        )
        self.conn.commit()
        if cur.lastrowid:
            return int(cur.lastrowid)
        row = self.conn.execute(
            "SELECT id FROM push_subscriptions WHERE device_token=? AND stop_id=? "
            "AND route_id IS ?",
            (device_token, stop_id, route_id),
        ).fetchone()
        return int(row["id"])

    def remove_subscription(self, sub_id: int, device_token: str) -> bool:
        cur = self.conn.execute(
            "DELETE FROM push_subscriptions WHERE id=? AND device_token=?", (sub_id, device_token)
        )
        self.conn.commit()
        return cur.rowcount > 0

    def subscriptions_for_stop(self, stop_id: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM push_subscriptions WHERE stop_id=?", (stop_id,)
        ).fetchall()
        return [dict(r) for r in rows]

    def mark_sent(self, sub_id: int, key: str, ts: float) -> None:
        self.enqueue(
            "UPDATE push_subscriptions SET last_sent_at=?, last_key=? WHERE id=?",
            (int(ts), key, sub_id),
        )

    def drop_token(self, device_token: str) -> None:
        self.enqueue("DELETE FROM push_subscriptions WHERE device_token=?", (device_token,))
