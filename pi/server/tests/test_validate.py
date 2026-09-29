from __future__ import annotations

import pytest

from app.pipeline import validate
from app.state import BusState
from conftest import feed


def test_parses_compact_payload():
    fix = validate.parse(
        {"seq": 1042, "t": 1790000000, "lat": 11.25874, "lng": 75.78012,
         "spd": 6.4, "hdg": 182, "sats": 9, "hdop": 1.1}
    )
    assert fix.seq == 1042
    assert fix.sats == 9
    assert fix.speed == 6.4


def test_missing_coordinates_is_rejected():
    with pytest.raises(validate.Rejected):
        validate.parse({"spd": 1})


def test_duplicate_and_out_of_order_seq_are_dropped(processor, cfg):
    t0 = 1790000000.0
    assert feed(processor, "bus1", 11.317194, 75.937560, t=t0, seq=10)
    assert not feed(processor, "bus1", 11.317200, 75.937560, t=t0 + 1, seq=10)
    assert not feed(processor, "bus1", 11.317200, 75.937560, t=t0 + 2, seq=9)
    assert feed(processor, "bus1", 11.317210, 75.937560, t=t0 + 3, seq=11)
    assert processor.live.get("bus1").last_seq == 11


def test_poor_fix_quality_is_rejected(processor):
    t0 = 1790000000.0
    assert not feed(processor, "bus1", 11.317194, 75.937560, t=t0, seq=1, sats=3)
    assert not feed(processor, "bus1", 11.317194, 75.937560, t=t0 + 1, seq=2, hdop=8.0)


def test_position_outside_campus_is_rejected(processor):
    assert not feed(processor, "bus1", 12.9716, 77.5946, t=1790000000.0, seq=1)


def test_implausible_jump_is_rejected(processor, cfg):
    t0 = 1790000000.0
    assert feed(processor, "bus1", 11.317194, 75.937560, t=t0, seq=1)
    # ~800 m in one second: a glitch, not a bus.
    assert not feed(processor, "bus1", 11.323114, 75.937258, t=t0 + 1, seq=2)
    assert processor.rejects["bus1"] == "implausible jump"


def test_unknown_bus_is_ignored(processor):
    assert not processor.handle_message("not_a_bus", {"lat": 11.318, "lng": 75.934})
