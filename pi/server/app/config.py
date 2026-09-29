"""Runtime settings. Every value is overridable by environment variable so the
same code runs on a laptop, in tests and on the Pi."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _f(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _i(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


def _p(name: str, default: Path) -> Path:
    v = os.environ.get(name)
    return Path(v) if v else default


REPO_ROOT = Path(__file__).resolve().parents[3]


@dataclass
class Settings:
    data_dir: Path = field(default_factory=lambda: _p("BUS_DATA_DIR", REPO_ROOT / "data"))
    db_path: Path = field(
        default_factory=lambda: _p("BUS_DB_PATH", Path("/var/lib/bustracker/bus.db"))
    )

    # A public broker, because nothing in this system can accept an inbound
    # connection: the buses are on cellular NAT and the Pi is on a phone
    # hotspot. Everything dials out to a meeting point instead. Free and
    # unauthenticated, which is why fixes are signed (see pipeline/authenticate).
    mqtt_host: str = os.environ.get("BUS_MQTT_HOST", "broker.emqx.io")
    mqtt_port: int = field(default_factory=lambda: _i("BUS_MQTT_PORT", 1883))
    mqtt_username: str = os.environ.get("BUS_MQTT_USERNAME", "")
    mqtt_password: str = os.environ.get("BUS_MQTT_PASSWORD", "")
    mqtt_enabled: bool = os.environ.get("BUS_MQTT_ENABLED", "1") != "0"

    # Everything hangs off one root. On a shared public broker a generic name
    # like "campus" collides with other people's traffic, so this is deliberately
    # unguessable -- hygiene, not security.
    topic_root: str = os.environ.get("BUS_TOPIC_ROOT", "cbt7f3c9e21b")

    # Fixes signed by the buses, and the processed state the app reads.
    topic_prefix: str = os.environ.get("BUS_TOPIC_PREFIX", "")
    live_topic_prefix: str = os.environ.get("BUS_LIVE_PREFIX", "")
    publish_live: bool = os.environ.get("BUS_PUBLISH_LIVE", "1") != "0"
    # Publish as soon as something changes, but no faster than this...
    live_min_interval: float = field(default_factory=lambda: _f("BUS_LIVE_MIN_INTERVAL", 1.0))
    # ...and republish at least this often even when nothing has, so status and
    # age transitions still reach the app. Phones pay for every byte too, so this
    # is deliberately not a fixed 1 Hz firehose.
    live_max_interval: float = field(default_factory=lambda: _f("BUS_LIVE_MAX_INTERVAL", 10.0))
    live_stop_interval: float = field(default_factory=lambda: _f("BUS_LIVE_STOP_INTERVAL", 15.0))

    # Shared secret for the direct HTTP test-injection route.
    ingest_tokens_path: Path = field(
        default_factory=lambda: _p("BUS_INGEST_TOKENS", Path("/etc/bustracker/ingest_tokens.json"))
    )

    # Per-device HMAC secrets, in the relay's devices.json format. Anyone can
    # publish to a public broker, so an unsigned fix is not worth acting on.
    bus_secrets_path: Path = field(
        default_factory=lambda: _p("BUS_SECRETS", Path("/etc/bustracker/devices.json"))
    )
    require_signature: bool = os.environ.get("BUS_REQUIRE_SIGNATURE", "1") != "0"

    broadcast_hz: float = field(default_factory=lambda: _f("BUS_BROADCAST_HZ", 1.0))
    db_flush_sec: float = field(default_factory=lambda: _f("BUS_DB_FLUSH_SEC", 5.0))
    track_sample_sec: float = field(default_factory=lambda: _f("BUS_TRACK_SAMPLE_SEC", 5.0))
    track_retain_days: int = field(default_factory=lambda: _i("BUS_TRACK_RETAIN_DAYS", 30))

    # Validation
    min_sats: int = field(default_factory=lambda: _i("BUS_MIN_SATS", 4))
    max_hdop: float = field(default_factory=lambda: _f("BUS_MAX_HDOP", 5.0))
    max_jump_mps: float = field(default_factory=lambda: _f("BUS_MAX_JUMP_MPS", 25.0))
    # Campus bbox with margin, matching tracker Config.bounds*.
    bbox_south: float = field(default_factory=lambda: _f("BUS_BBOX_SOUTH", 11.312581))
    bbox_west: float = field(default_factory=lambda: _f("BUS_BBOX_WEST", 75.928695))
    bbox_north: float = field(default_factory=lambda: _f("BUS_BBOX_NORTH", 11.325470))
    bbox_east: float = field(default_factory=lambda: _f("BUS_BBOX_EAST", 75.940230))

    # Smoothing: 0 = no smoothing, 1 = ignore new fixes. Tuned for the 5 s fix
    # interval in HARDWARE.md §6.1 — fixes that far apart are genuinely different
    # positions, so heavy smoothing would just lag the bus behind where it is.
    pos_smoothing: float = field(default_factory=lambda: _f("BUS_POS_SMOOTHING", 0.2))
    speed_smoothing: float = field(default_factory=lambda: _f("BUS_SPEED_SMOOTHING", 0.4))

    # Map matching / route inference
    snap_radius_m: float = field(default_factory=lambda: _f("BUS_SNAP_RADIUS_M", 30.0))
    progress_back_tolerance_m: float = field(default_factory=lambda: _f("BUS_PROGRESS_BACK_M", 15.0))
    route_switch_margin: float = field(default_factory=lambda: _f("BUS_ROUTE_SWITCH_MARGIN", 4.0))
    route_score_decay: float = field(default_factory=lambda: _f("BUS_ROUTE_SCORE_DECAY", 0.9))
    schedule_prior_window_min: int = field(default_factory=lambda: _i("BUS_SCHED_WINDOW_MIN", 20))

    # Stop geofence (hysteresis: enter tighter than exit)
    stop_enter_m: float = field(default_factory=lambda: _f("BUS_STOP_ENTER_M", 40.0))
    stop_exit_m: float = field(default_factory=lambda: _f("BUS_STOP_EXIT_M", 60.0))
    stop_min_dwell_sec: float = field(default_factory=lambda: _f("BUS_STOP_MIN_DWELL_SEC", 5.0))

    # Journey state machine, carried over from the Supabase implementation.
    arrive_radius_m: float = field(default_factory=lambda: _f("BUS_ARRIVE_RADIUS_M", 40.0))
    parked_window_sec: float = field(default_factory=lambda: _f("BUS_PARKED_WINDOW_SEC", 30.0))
    parked_max_drift_m: float = field(default_factory=lambda: _f("BUS_PARKED_MAX_DRIFT_M", 15.0))
    depart_min_distance_m: float = field(default_factory=lambda: _f("BUS_DEPART_MIN_DIST_M", 25.0))
    depart_min_speed_mps: float = field(default_factory=lambda: _f("BUS_DEPART_MIN_SPEED", 2.0))
    depart_min_fixes: int = field(default_factory=lambda: _i("BUS_DEPART_MIN_FIXES", 3))

    # Motion / distance
    moving_speed_mps: float = field(default_factory=lambda: _f("BUS_MOVING_SPEED_MPS", 0.8))

    # ETA
    eta_min_speed_mps: float = field(default_factory=lambda: _f("BUS_ETA_MIN_SPEED", 2.0))
    eta_avg_speed_mps: float = field(default_factory=lambda: _f("BUS_ETA_AVG_SPEED", 5.0))
    eta_hist_full_samples: int = field(default_factory=lambda: _i("BUS_ETA_HIST_N", 20))
    eta_hist_weight_cap: float = field(default_factory=lambda: _f("BUS_ETA_HIST_CAP", 0.7))
    terminal_dwell_sec: int = field(default_factory=lambda: _i("BUS_TERMINAL_DWELL_SEC", 180))

    # Status thresholds (seconds since last accepted fix), sized against the 5 s
    # fix interval the hardware actually sends: one missed fix is normal on 2G,
    # two is worth flagging, and a 2G reconnect can legitimately take ~a minute.
    live_max_age: float = field(default_factory=lambda: _f("BUS_LIVE_MAX_AGE", 12.0))
    delayed_max_age: float = field(default_factory=lambda: _f("BUS_DELAYED_MAX_AGE", 30.0))
    stale_max_age: float = field(default_factory=lambda: _f("BUS_STALE_MAX_AGE", 120.0))

    # Push
    fcm_credentials: Path = field(
        default_factory=lambda: _p("BUS_FCM_CREDENTIALS", Path("/etc/bustracker/fcm-service-account.json"))
    )
    fcm_project_id: str = os.environ.get("BUS_FCM_PROJECT_ID", "")
    push_enabled: bool = os.environ.get("BUS_PUSH_ENABLED", "0") == "1"
    push_repeat_cooldown_sec: int = field(default_factory=lambda: _i("BUS_PUSH_COOLDOWN_SEC", 900))

    timezone: str = os.environ.get("BUS_TZ", "Asia/Kolkata")

    @property
    def center(self) -> tuple[float, float]:
        return (
            (self.bbox_south + self.bbox_north) / 2,
            (self.bbox_west + self.bbox_east) / 2,
        )

    @property
    def bus_topics(self) -> str:
        return self.topic_prefix or f"{self.topic_root}/bus"

    @property
    def live_topics(self) -> str:
        return self.live_topic_prefix or f"{self.topic_root}/live"

    def in_bbox(self, lat: float, lng: float) -> bool:
        return (
            self.bbox_south <= lat <= self.bbox_north
            and self.bbox_west <= lng <= self.bbox_east
        )


settings = Settings()
