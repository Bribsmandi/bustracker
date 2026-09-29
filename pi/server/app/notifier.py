"""Push alerts via FCM HTTP v1.

The only place this design touches Google infrastructure, and only to deliver a
notification — no position stream leaves the Pi. FCM relays to Apple for iOS, so
there is no separate Apple integration here.

Dedup is per bus-arrival rather than per tick: a student subscribed to "5 minutes
before" gets one alert for a given bus approaching, not one a second while the
ETA hovers around the threshold.
"""
from __future__ import annotations

import asyncio
import logging
import time

from .config import Settings, settings
from .db import Database
from .planner import Planner

log = logging.getLogger("bus.notifier")

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
CHECK_INTERVAL_SEC = 15.0


class Notifier:
    def __init__(self, planner: Planner, db: Database, cfg: Settings | None = None):
        self.planner = planner
        self.db = db
        self.cfg = cfg or settings
        self._creds = None
        self._session = None

    # ------------------------------------------------------------------ setup

    def _ensure_client(self) -> bool:
        if self._session is not None:
            return True
        try:
            import google.auth.transport.requests as ga_requests
            from google.oauth2 import service_account
        except ImportError:
            log.error("push enabled but google-auth is not installed")
            return False
        if not self.cfg.fcm_credentials.exists():
            log.error("push enabled but %s is missing", self.cfg.fcm_credentials)
            return False
        self._creds = service_account.Credentials.from_service_account_file(
            str(self.cfg.fcm_credentials), scopes=[FCM_SCOPE]
        )
        self._session = ga_requests.AuthorizedSession(self._creds)
        return True

    # ------------------------------------------------------------------- loop

    async def run(self) -> None:
        if not self.cfg.push_enabled:
            log.info("push notifications disabled")
            return
        if not await asyncio.to_thread(self._ensure_client):
            return
        while True:
            await asyncio.sleep(CHECK_INTERVAL_SEC)
            try:
                await self.tick()
            except Exception:
                log.exception("notifier tick failed")

    async def tick(self, now: float | None = None) -> int:
        now = time.time() if now is None else now
        sent = 0
        for stop_id in self._subscribed_stops():
            arrivals = self.planner.arrivals(stop_id, now)["arrivals"]
            if not arrivals:
                continue
            for sub in self.db.subscriptions_for_stop(stop_id):
                match = self._match(sub, arrivals)
                if match is None:
                    continue
                key = self._key(match, stop_id)
                if sub["last_key"] == key:
                    continue
                if (
                    sub["last_sent_at"] is not None
                    and now - sub["last_sent_at"] < self.cfg.push_repeat_cooldown_sec
                    and sub["last_key"] == key
                ):
                    continue
                if await self._send(sub, stop_id, match):
                    self.db.mark_sent(sub["id"], key, now)
                    sent += 1
        return sent

    def _subscribed_stops(self) -> list[str]:
        rows = self.db.conn.execute("SELECT DISTINCT stop_id FROM push_subscriptions").fetchall()
        return [r["stop_id"] for r in rows]

    def _match(self, sub: dict, arrivals: list[dict]) -> dict | None:
        lead_s = sub["lead_minutes"] * 60
        for a in arrivals:
            if sub["route_id"] and a["route_id"] != sub["route_id"]:
                continue
            if a["source"] == "timetable":
                continue
            if a["eta_s"] <= lead_s:
                return a
        return None

    def _key(self, arrival: dict, stop_id: str) -> str:
        state = self.planner.p.live.get(arrival["bus_id"])
        trip = state.trip_id if state else None
        return f"{arrival['bus_id']}:{arrival['route_id']}:{stop_id}:{trip}"

    async def _send(self, sub: dict, stop_id: str, arrival: dict) -> bool:
        data = self.planner.data
        stop = data.stops.get(stop_id)
        bus = data.buses.get(arrival["bus_id"])
        minutes = max(1, round(arrival["eta_s"] / 60))
        message = {
            "message": {
                "token": sub["device_token"],
                "notification": {
                    "title": f"{bus.label if bus else arrival['bus_id']} approaching",
                    "body": f"Arriving at {stop.name if stop else stop_id} in about {minutes} min",
                },
                "data": {
                    "stop_id": stop_id,
                    "bus_id": arrival["bus_id"],
                    "route_id": arrival["route_id"] or "",
                    "eta_s": str(arrival["eta_s"]),
                },
                "android": {"priority": "high"},
            }
        }
        url = f"https://fcm.googleapis.com/v1/projects/{self.cfg.fcm_project_id}/messages:send"
        try:
            resp = await asyncio.to_thread(self._session.post, url, json=message, timeout=10)
        except Exception:
            log.exception("FCM send failed")
            return False
        if resp.status_code == 200:
            return True
        if resp.status_code in (404, 400) and "UNREGISTERED" in resp.text:
            # The app was uninstalled or the token rotated.
            log.info("dropping dead token for subscription %s", sub["id"])
            self.db.drop_token(sub["device_token"])
            return False
        log.warning("FCM %s: %s", resp.status_code, resp.text[:200])
        return False
