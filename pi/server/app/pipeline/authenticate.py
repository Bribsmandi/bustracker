"""Signature checking for fixes that arrive straight from a bus.

The relay used to do this before republishing. With the buses publishing to a
public broker themselves, there is no relay in the path, so the Pi verifies.

It matters more here than it did there: on a shared public broker anyone can
publish to these topics. Without this, a stray message -- or someone bored --
would move a bus on the map. With it, only the six units holding a secret can.

Wire format, because MQTT has no header to put the signature in:

    <64 hex chars>.<the exact JSON bytes that were signed>

The signature covers the JSON portion verbatim. Splitting rather than re-parsing
means the bytes verified are the bytes sent, which is the property that makes a
signature worth anything.
"""
from __future__ import annotations

import hashlib
import hmac
import json

from .validate import Rejected

SIG_LEN = 64


def load_secrets(path) -> dict[str, dict]:
    """Read the relay's devices.json format: {device_id: {bus_id, secret}}."""
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return {}
    out: dict[str, dict] = {}
    for device_id, entry in raw.items():
        if isinstance(entry, dict) and "secret" in entry and "bus_id" in entry:
            out[str(device_id)] = {"bus_id": str(entry["bus_id"]), "secret": str(entry["secret"])}
    return out


def verify(raw: str, bus_id: str, secrets: dict[str, dict]) -> dict:
    """Return the fix payload, or raise Rejected.

    `bus_id` is the one from the topic; the signed body carries its own, and the
    two must agree or a unit could publish as another bus.
    """
    dot = raw.find(".")
    if dot != SIG_LEN:
        raise Rejected("malformed signed payload")
    supplied = raw[:SIG_LEN].lower()
    body = raw[SIG_LEN + 1 :]
    if not body:
        raise Rejected("empty body")

    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        raise Rejected("bad json")
    if not isinstance(payload, dict):
        raise Rejected("bad json")

    device_id = payload.get("d")
    if not isinstance(device_id, str):
        raise Rejected("no device id")
    device = secrets.get(device_id)
    if device is None:
        raise Rejected("unknown device")

    expected = hmac.new(device["secret"].encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, supplied):
        raise Rejected("bad signature")

    # A device may only publish as the bus it is bound to, and only on that
    # bus's topic. Both are checked: the topic could be forged by anyone, and
    # the body is only trustworthy once the signature above has passed.
    if device["bus_id"] != bus_id:
        raise Rejected("wrong topic for this device")
    if payload.get("b") != bus_id:
        raise Rejected("wrong bus")

    return normalise(payload)


def normalise(payload: dict) -> dict:
    """Map the device's compact field names onto the pipeline's.

    The hardware sends `c` for its monotonic counter; everything downstream
    calls that `seq`.
    """
    out = {k: payload[k] for k in ("lat", "lng") if k in payload}
    if "c" in payload:
        out["seq"] = payload["c"]
    if payload.get("spd") is not None:
        out["spd"] = payload["spd"]
    if payload.get("hdg") is not None:
        out["hdg"] = payload["hdg"]
    for extra in ("sats", "hdop", "t"):
        if payload.get(extra) is not None:
            out[extra] = payload[extra]
    return out
