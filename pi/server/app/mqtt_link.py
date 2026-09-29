"""The Pi's single connection to the broker: raw fixes in, processed state out.

The broker is on the public VM because the Pi cannot be dialled into from
outside campus NAT. So this is an ordinary outbound client connection — the same
thing a phone makes — and it carries traffic in both directions:

    subscribe  campus/bus/+/gps      raw fixes, republished by the relay
    subscribe  campus/bus/+/status   online/offline, driven by the relay watchdog
    publish    campus/live/buses     the processed snapshot the app renders
    publish    campus/live/stop/{id} per-stop arrival estimates

paho runs its network loop on its own thread; incoming messages are handed to the
event loop with call_soon_threadsafe so the pipeline only ever runs on the loop
thread and needs no locking around live state.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time

import paho.mqtt.client as mqtt

from .config import Settings, settings
from .planner import Planner
from .processor import Processor

log = logging.getLogger("bus.mqtt")

POLL_INTERVAL = 0.5


class MqttLink:
    def __init__(self, processor: Processor, planner: Planner, cfg: Settings | None = None):
        self.p = processor
        self.planner = planner
        self.cfg = cfg or settings
        self.loop: asyncio.AbstractEventLoop | None = None
        self.connected = False
        self.published = 0

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id="bustracker-processor", clean_session=True
        )
        if self.cfg.mqtt_username:
            self.client.username_pw_set(self.cfg.mqtt_username, self.cfg.mqtt_password)
        self.client.reconnect_delay_set(min_delay=1, max_delay=10)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message

    async def start(self) -> None:
        self.loop = asyncio.get_running_loop()
        try:
            self.client.connect_async(self.cfg.mqtt_host, self.cfg.mqtt_port, keepalive=30)
        except Exception:
            log.exception("mqtt connect failed; paho will retry")
        self.client.loop_start()

    async def stop(self) -> None:
        self.client.loop_stop()
        try:
            self.client.disconnect()
        except Exception:
            pass

    # ----------------------------------------------------------- paho thread

    def _on_connect(self, client, userdata, flags, reason_code, properties=None) -> None:
        if getattr(reason_code, "is_failure", False):
            log.error("mqtt connect refused: %s", reason_code)
            return
        self.connected = True
        prefix = self.cfg.topic_prefix
        client.subscribe([(f"{prefix}/+/gps", 0), (f"{prefix}/+/status", 1)])
        log.info(
            "mqtt connected to %s:%d, subscribed under %s/+/",
            self.cfg.mqtt_host,
            self.cfg.mqtt_port,
            prefix,
        )

    def _on_disconnect(self, client, userdata, flags, reason_code, properties=None) -> None:
        self.connected = False
        log.warning("mqtt disconnected: %s", reason_code)

    def _on_message(self, client, userdata, msg: mqtt.MQTTMessage) -> None:
        if self.loop is None:
            return
        parts = msg.topic.split("/")
        if len(parts) < 2:
            return
        kind, bus_id = parts[-1], parts[-2]
        try:
            raw = msg.payload.decode()
        except UnicodeDecodeError:
            log.info("undecodable payload on %s", msg.topic)
            return

        if kind == "status":
            self.loop.call_soon_threadsafe(self.p.handle_status, bus_id, raw)
            return
        if kind != "gps":
            return
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            log.info("bad json on %s", msg.topic)
            return
        if not isinstance(payload, dict):
            return
        self.loop.call_soon_threadsafe(self.p.handle_message, bus_id, payload)

    # ------------------------------------------------------------- publishing

    def _publish(self, topic: str, payload: dict) -> None:
        if not self.connected:
            return
        self.client.publish(
            topic, json.dumps(payload, separators=(",", ":")), qos=0, retain=True
        )
        self.published += 1

    async def run_publisher(self) -> None:
        """Push the processed snapshot out when it changes.

        Retained, so a phone opening the app receives the current state on
        subscribe with no request/response round trip. Publishing is driven by
        change rather than a fixed rate: the buses only report every 5 s, and a
        1 Hz firehose would spend students' mobile data re-sending what they
        already have.
        """
        if not self.cfg.publish_live:
            log.info("live publishing disabled")
            return

        last_live = 0.0
        last_stops = 0.0
        config_version: str | None = None
        while True:
            await asyncio.sleep(POLL_INTERVAL)
            now = time.time()

            # Stops, routes and the timetable, retained. Means the app needs no
            # HTTP call at all for the map — and a data fix still reaches it
            # without an app release.
            if self.connected and config_version != self.p.data.version:
                try:
                    self._publish(
                        f"{self.cfg.live_topic_prefix}/config", self.p.data.config_payload()
                    )
                    config_version = self.p.data.version
                    log.info("published config version %s", config_version)
                except Exception:
                    log.exception("publishing config failed")

            due = self.p.dirty and now - last_live >= self.cfg.live_min_interval
            stale = now - last_live >= self.cfg.live_max_interval
            if due or stale:
                self.p.dirty = False
                last_live = now
                try:
                    self._publish(f"{self.cfg.live_topic_prefix}/buses", self.p.snapshot(now))
                except Exception:
                    log.exception("publishing snapshot failed")

            if now - last_stops >= self.cfg.live_stop_interval:
                last_stops = now
                try:
                    for stop_id in self.p.data.stops:
                        self._publish(
                            f"{self.cfg.live_topic_prefix}/stop/{stop_id}",
                            self.planner.arrivals(stop_id, now),
                        )
                except Exception:
                    log.exception("publishing stop arrivals failed")
