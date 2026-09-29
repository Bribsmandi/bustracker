from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from app import config as config_mod
from app.main import create_app
from test_pipeline import T0, drive


@pytest.fixture
def client(tmp_path, monkeypatch):
    s = config_mod.settings
    monkeypatch.setattr(s, "db_path", tmp_path / "api.db")
    monkeypatch.setattr(s, "mqtt_enabled", False)
    monkeypatch.setattr(s, "push_enabled", False)
    monkeypatch.setattr(s, "ingest_tokens_path", tmp_path / "tokens.json")
    (tmp_path / "tokens.json").write_text(json.dumps({"bus1": "secret-token"}))
    with TestClient(create_app()) as c:
        yield c


def test_health_reports_the_fleet(client):
    body = client.get("/health").json()
    assert body["ok"] is True
    assert body["buses_total"] == 6
    assert body["buses_online"] == 0
    assert body["mqtt_connected"] is False


def test_config_serves_the_canonical_data_files(client):
    body = client.get("/config").json()
    assert len(body["stops"]) == 8
    assert len(body["buses"]) == 6
    assert len(body["routes"]) == 10
    assert body["version"]


def test_buses_snapshot_shape(client):
    body = client.get("/buses").json()
    assert body["type"] == "snapshot"
    ids = {b["id"] for b in body["buses"]}
    assert ids == {"bus1", "bus2", "bus3", "bus4", "ac_mbh", "ac_lh"}
    assert all(b["status"] == "offline" for b in body["buses"])


def test_ingest_fallback_accepts_a_signed_position(client):
    r = client.post(
        "/ingest/bus1",
        json={"lat": 11.317194, "lng": 75.937560, "seq": 1, "spd": 5.0, "sats": 9, "hdop": 1.0},
        headers={"Authorization": "Bearer secret-token"},
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    assert client.get("/health").json()["buses_online"] == 1


def test_ingest_rejects_a_bad_token(client):
    r = client.post(
        "/ingest/bus1",
        json={"lat": 11.317194, "lng": 75.937560},
        headers={"Authorization": "Bearer wrong"},
    )
    assert r.status_code == 403


def test_ingest_rejects_an_unconfigured_bus(client):
    r = client.post(
        "/ingest/bus2",
        json={"lat": 11.317194, "lng": 75.937560},
        headers={"Authorization": "Bearer secret-token"},
    )
    assert r.status_code == 403


def test_arrivals_falls_back_to_the_timetable_when_nothing_is_live(client):
    body = client.get("/stops/library/arrivals").json()
    assert body["stop_id"] == "library"
    assert all(a["source"] == "timetable" for a in body["arrivals"])
    assert all(a["confident"] is False for a in body["arrivals"])


def test_arrivals_rejects_an_unknown_stop(client):
    assert client.get("/stops/nowhere/arrivals").status_code == 404


def test_trip_planner_requires_both_ends(client):
    assert client.get("/trip?from=mbh").status_code == 400
    assert client.get("/trip?from=mbh&to=mbh").status_code == 400
    body = client.get("/trip?from=mbh&to=east_campus").json()
    assert body["from"] == "mbh"
    assert all(o["total_s"] >= o["ride_s"] for o in body["options"])


def test_trip_planner_respects_direction(client):
    # mbh -> east_campus exists; the reverse must use the return route, never the
    # outbound one read backwards.
    out = client.get("/trip?from=mbh&to=east_campus").json()["options"]
    back = client.get("/trip?from=east_campus&to=mbh").json()["options"]
    assert {o["route_id"] for o in out} <= {"mbh_to_east", "ac_mbh_out"}
    assert {o["route_id"] for o in back} <= {"east_to_mbh", "ac_arch_to_mbh"}


def test_subscription_lifecycle(client):
    created = client.post(
        "/subscriptions",
        json={"device_token": "device-token-123", "stop_id": "library", "lead_minutes": 5},
    )
    assert created.status_code == 201
    sub_id = created.json()["id"]

    assert client.delete(f"/subscriptions/{sub_id}").status_code == 401
    ok = client.delete(
        f"/subscriptions/{sub_id}", headers={"X-Device-Token": "device-token-123"}
    )
    assert ok.status_code == 200
    assert (
        client.delete(
            f"/subscriptions/{sub_id}", headers={"X-Device-Token": "device-token-123"}
        ).status_code
        == 404
    )


def test_subscription_rejects_unknown_stop(client):
    r = client.post(
        "/subscriptions", json={"device_token": "device-token-123", "stop_id": "nowhere"}
    )
    assert r.status_code == 400


def test_websocket_sends_a_snapshot_on_connect(client):
    with client.websocket_connect("/ws/live") as ws:
        frame = ws.receive_json()
    assert frame["type"] == "snapshot"
    assert len(frame["buses"]) == 6


def test_analytics_endpoints_respond_when_empty(client):
    assert client.get("/analytics/buses").json()["buses"] == []
    assert client.get("/analytics/stops/library").json()["samples"] == 0
    assert client.get("/analytics/trips").json()["trips"] == []
    assert client.get("/analytics/stops/nowhere").status_code == 404


def test_live_bus_appears_in_arrivals(client):
    processor = client.app.state.processor
    drive(processor, "bus1", "mbh_to_east", start=T0, to_m=200, speed=8.0)
    state = processor.live.get("bus1")
    # The snapshot ages off wall-clock time, so pin the fix to now.
    import time

    state.last_accepted_at = time.time()

    body = client.get("/stops/library/arrivals").json()
    live = [a for a in body["arrivals"] if a["bus_id"] == "bus1" and a["source"] != "timetable"]
    assert live and live[0]["eta_s"] > 0
