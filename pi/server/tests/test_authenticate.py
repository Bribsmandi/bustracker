from __future__ import annotations

import hashlib
import hmac
import json

import pytest

from app.pipeline import authenticate
from app.pipeline.validate import Rejected

SECRETS = {
    "esp32-01": {"bus_id": "bus1", "secret": "aabbccdd" * 4},
    "esp32-03": {"bus_id": "bus3", "secret": "11223344" * 4},
}


def sign(body: str, secret: str) -> str:
    return hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()


def signed(bus="bus1", device="esp32-01", counter=1000, secret=None, **over) -> str:
    body = json.dumps(
        {"b": bus, "d": device, "c": counter, "lat": 11.3185, "lng": 75.9379,
         "spd": 6.4, "hdg": 312, **over},
        separators=(",", ":"),
    )
    return f"{sign(body, secret or SECRETS[device]['secret'])}.{body}"


# ------------------------------------------------------------------ accepting


def test_a_correctly_signed_fix_is_accepted():
    out = authenticate.verify(signed(), "bus1", SECRETS)
    assert out["lat"] == 11.3185
    assert out["lng"] == 75.9379
    assert out["spd"] == 6.4


def test_the_device_counter_becomes_seq():
    """The hardware calls it `c`; everything downstream calls it `seq`."""
    out = authenticate.verify(signed(counter=4242), "bus1", SECRETS)
    assert out["seq"] == 4242
    assert "c" not in out


def test_null_heading_is_dropped_rather_than_sent_as_zero():
    out = authenticate.verify(signed(hdg=None), "bus1", SECRETS)
    assert "hdg" not in out


def test_optional_quality_fields_pass_through_when_present():
    out = authenticate.verify(signed(sats=9, hdop=1.1), "bus1", SECRETS)
    assert out["sats"] == 9
    assert out["hdop"] == 1.1


# ------------------------------------------------------------------ rejecting


def test_a_tampered_body_is_rejected():
    """The whole point: on a public broker anyone can publish here."""
    raw = signed()
    sig, body = raw.split(".", 1)
    moved = body.replace("11.3185", "11.3200")
    with pytest.raises(Rejected, match="bad signature"):
        authenticate.verify(f"{sig}.{moved}", "bus1", SECRETS)


def test_an_unsigned_message_is_rejected():
    body = '{"b":"bus1","d":"esp32-01","c":1,"lat":11.3185,"lng":75.9379}'
    with pytest.raises(Rejected, match="malformed"):
        authenticate.verify(body, "bus1", SECRETS)


def test_a_signature_from_the_wrong_secret_is_rejected():
    body = json.dumps({"b": "bus1", "d": "esp32-01", "c": 1, "lat": 11.3, "lng": 75.9},
                      separators=(",", ":"))
    with pytest.raises(Rejected, match="bad signature"):
        authenticate.verify(f"{sign(body, 'not-the-secret')}.{body}", "bus1", SECRETS)


def test_an_unknown_device_is_rejected():
    with pytest.raises(Rejected, match="unknown device"):
        authenticate.verify(signed(device="esp32-01", secret="x" * 32).replace(
            '"d":"esp32-01"', '"d":"esp32-99"'), "bus1", SECRETS)


def test_a_device_cannot_publish_as_another_bus():
    """Even correctly signed: esp32-01 is bound to bus1, so bus3's topic is not
    its to publish on."""
    raw = signed(bus="bus3", device="esp32-01")
    with pytest.raises(Rejected, match="wrong topic"):
        authenticate.verify(raw, "bus3", SECRETS)


def test_a_body_claiming_a_different_bus_than_its_topic_is_rejected():
    # Correctly signed by esp32-03 (bound to bus3) but the body says bus1.
    body = json.dumps({"b": "bus1", "d": "esp32-03", "c": 1, "lat": 11.3, "lng": 75.9},
                      separators=(",", ":"))
    raw = f"{sign(body, SECRETS['esp32-03']['secret'])}.{body}"
    with pytest.raises(Rejected, match="wrong bus"):
        authenticate.verify(raw, "bus3", SECRETS)


@pytest.mark.parametrize("raw", [
    "",
    ".",
    "short.{}",
    "z" * 64 + ".{}",
    "a" * 64 + ".",
    "a" * 64 + ".not json",
    "a" * 64 + '.["a","list"]',
    "a" * 65 + ".{}",
])
def test_malformed_payloads_raise_rather_than_crash(raw):
    with pytest.raises(Rejected):
        authenticate.verify(raw, "bus1", SECRETS)


def test_no_device_field_is_rejected():
    body = '{"b":"bus1","c":1,"lat":11.3,"lng":75.9}'
    with pytest.raises(Rejected, match="no device id"):
        authenticate.verify(f"{sign(body, 'x')}.{body}", "bus1", SECRETS)


# -------------------------------------------------------------- secrets file


def test_load_secrets_reads_the_relay_format(tmp_path):
    f = tmp_path / "devices.json"
    f.write_text(json.dumps({
        "esp32-01": {"bus_id": "bus1", "secret": "abc"},
        "broken": {"bus_id": "bus2"},
        "also-broken": "not a dict",
    }))
    out = authenticate.load_secrets(f)
    assert out == {"esp32-01": {"bus_id": "bus1", "secret": "abc"}}


def test_missing_secrets_file_is_not_fatal(tmp_path):
    assert authenticate.load_secrets(tmp_path / "nope.json") == {}


# ------------------------------------------------------ end to end via processor


def test_processor_accepts_a_signed_fix(processor, cfg):
    cfg.require_signature = True
    processor.secrets = SECRETS
    mbh = processor.data.stops["mbh"]
    body = json.dumps({"b": "bus1", "d": "esp32-01", "c": 1,
                       "lat": mbh.lat, "lng": mbh.lng, "spd": 0.0, "hdg": None},
                      separators=(",", ":"))
    raw = f"{sign(body, SECRETS['esp32-01']['secret'])}.{body}"
    assert processor.handle_signed("bus1", raw, now=1790000000.0)
    assert processor.live.get("bus1").lat == pytest.approx(mbh.lat)


def test_processor_rejects_an_unsigned_fix_when_signing_is_required(processor, cfg):
    cfg.require_signature = True
    processor.secrets = SECRETS
    assert not processor.handle_signed(
        "bus1", '{"b":"bus1","lat":11.3185,"lng":75.9379}', now=1790000000.0
    )
    assert processor.rejects["bus1"] == "malformed signed payload"


def test_processor_refuses_everything_when_no_secrets_are_loaded(processor, cfg):
    """Failing closed matters: the alternative is silently trusting a public
    broker."""
    cfg.require_signature = True
    processor.secrets = {}
    assert not processor.handle_signed("bus1", signed(), now=1790000000.0)
    assert processor.rejects["bus1"] == "no secrets loaded"
