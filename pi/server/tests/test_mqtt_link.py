from __future__ import annotations

import asyncio
import json

import pytest

from app.mqtt_link import MqttLink
from conftest import feed
from test_pipeline import T0


class FakeClient:
    """Stands in for paho, recording what would go on the wire."""

    def __init__(self):
        self.published: list[tuple[str, str, int, bool]] = []
        self.subscribed: list = []

    def publish(self, topic, payload, qos=0, retain=False):
        self.published.append((topic, payload, qos, retain))

    def subscribe(self, topics):
        self.subscribed.append(topics)

    def username_pw_set(self, *a, **k):
        pass

    def reconnect_delay_set(self, *a, **k):
        pass

    def will_set(self, *a, **k):
        pass

    def topics(self):
        return [t for t, _, _, _ in self.published]


@pytest.fixture
def link(processor, planner, cfg):
    lk = MqttLink(processor, planner, cfg=cfg)
    lk.client = FakeClient()
    lk.connected = True
    lk.loop = asyncio.new_event_loop()
    return lk


# --------------------------------------------- the payload the relay publishes


def test_relay_payload_shape_is_accepted(processor):
    """relay.py maps the device's `c` counter to `seq` and drops the fields the
    hardware does not send. This is the exact contract between the two."""
    payload = json.loads('{"seq":1234,"lat":11.317194,"lng":75.937560,"spd":6.4,"hdg":312}')
    assert processor.handle_message("bus1", payload, now=T0)
    state = processor.live.get("bus1")
    assert state.last_seq == 1234
    assert state.speed > 0


def test_fix_without_quality_fields_is_still_accepted(processor):
    """HARDWARE.md sends no sats/hdop/t, so those gates must no-op rather than
    reject everything."""
    assert processor.handle_message(
        "bus1", {"seq": 1, "lat": 11.317194, "lng": 75.937560, "spd": 3.0}, now=T0
    )


def test_null_heading_is_accepted(processor):
    """§8: send hdg null when unknown, never 0."""
    assert processor.handle_message(
        "bus1", {"seq": 1, "lat": 11.317194, "lng": 75.937560, "spd": 0.0, "hdg": None}, now=T0
    )
    assert processor.live.get("bus1").raw_heading is None


def test_counter_replay_is_still_rejected_downstream(processor):
    assert processor.handle_message("bus1", {"seq": 5, "lat": 11.317194, "lng": 75.93756}, now=T0)
    assert not processor.handle_message(
        "bus1", {"seq": 5, "lat": 11.317194, "lng": 75.93756}, now=T0 + 5
    )


# ------------------------------------------------------------ topic handling


def test_gps_and_status_topics_are_routed(link, processor, cfg):
    class Msg:
        def __init__(self, topic, payload):
            self.topic = topic
            self.payload = payload.encode()

    calls: list = []
    link.loop.call_soon_threadsafe = lambda fn, *a: calls.append((fn.__name__, a))

    root = cfg.bus_topics
    link._on_message(None, None, Msg(f"{root}/bus1/gps", '{"seq":1,"lat":11.3,"lng":75.9}'))
    link._on_message(None, None, Msg(f"{root}/bus3/status", "offline"))
    link._on_message(None, None, Msg(f"{root}/bus1/unknown", "x"))

    # A gps publish is handed on verbatim: the processor verifies its signature
    # before anything is parsed, so malformed payloads are its business.
    assert [c[0] for c in calls] == ["handle_signed", "handle_status"]
    assert calls[0][1][0] == "bus1"
    assert calls[1][1] == ("bus3", "offline")


def test_subscribes_to_both_topic_families(link, cfg):
    link._on_connect(link.client, None, None, type("RC", (), {"is_failure": False})())
    root = cfg.bus_topics
    assert link.client.subscribed == [[(f"{root}/+/gps", 0), (f"{root}/+/status", 1)]]


# ---------------------------------------------------------------- publishing


async def _run_publisher_briefly(link, seconds: float = 0.0):
    task = asyncio.create_task(link.run_publisher())
    await asyncio.sleep(seconds)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


def test_snapshot_is_published_retained(link, processor, cfg):
    """Retained so a phone opening the app gets current state on subscribe."""
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    asyncio.run(_run_publisher_briefly(link, 0.7))

    live = [p for p in link.client.published if p[0] == f"{cfg.live_topics}/buses"]
    assert live
    topic, payload, qos, retain = live[0]
    assert retain is True
    body = json.loads(payload)
    assert body["type"] == "snapshot"
    assert len(body["buses"]) == 6


def test_stop_arrivals_are_published_per_stop(link, processor, cfg):
    asyncio.run(_run_publisher_briefly(link, 0.7))
    stop_topics = {t for t in link.client.topics() if t.startswith(f"{cfg.live_topics}/stop/")}
    assert f"{cfg.live_topics}/stop/library" in stop_topics
    assert len(stop_topics) == len(processor.data.stops)


def test_publishing_is_skipped_while_disconnected(link, processor):
    link.connected = False
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    asyncio.run(_run_publisher_briefly(link, 0.7))
    assert link.client.published == []


def test_disabled_publisher_returns_immediately(link, cfg, processor):
    cfg.publish_live = False
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    asyncio.run(_run_publisher_briefly(link, 0.7))
    assert link.client.published == []


def test_dirty_flag_drives_publishing(processor):
    assert processor.dirty is False
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    assert processor.dirty is True


def test_status_change_marks_state_dirty(processor):
    processor.dirty = False
    processor.handle_status("bus1", "offline")
    assert processor.dirty is True
    # No change, so nothing new to send.
    processor.dirty = False
    processor.handle_status("bus1", "offline")
    assert processor.dirty is False


def test_config_is_published_retained_once(link, processor, cfg):
    """The app gets stops/routes/timetable over MQTT, so it needs no HTTP call
    to draw the map. Published once, not on every tick."""
    asyncio.run(_run_publisher_briefly(link, 1.4))
    configs = [p for p in link.client.published if p[0] == f"{cfg.live_topics}/config"]
    assert len(configs) == 1
    topic, payload, qos, retain = configs[0]
    assert retain is True
    body = json.loads(payload)
    assert body["version"] == processor.data.version
    assert len(body["routes"]) == 10
    assert len(body["stops"]) == 8


# ------------------------------------------------- server presence (retained)


def test_last_will_marks_the_server_offline(processor, planner, cfg):
    """Every live topic is retained, so a snapshot outlives this process. The
    Will is what stops the app rendering a dead server's last words forever."""
    calls = []

    class WillClient(FakeClient):
        def will_set(self, topic, payload, qos=0, retain=False):
            calls.append((topic, payload, qos, retain))

    import app.mqtt_link as ml

    real = ml.mqtt.Client
    ml.mqtt.Client = lambda *a, **k: WillClient()
    try:
        MqttLink(processor, planner, cfg=cfg)
    finally:
        ml.mqtt.Client = real

    assert calls == [(f"{cfg.live_topics}/server", "offline", 1, True)]


def test_server_announces_itself_online_on_connect(link, cfg):
    link._on_connect(link.client, None, None, type("RC", (), {"is_failure": False})())
    online = [p for p in link.client.published if p[0] == f"{cfg.live_topics}/server"]
    assert online == [(f"{cfg.live_topics}/server", "online", 1, True)]
