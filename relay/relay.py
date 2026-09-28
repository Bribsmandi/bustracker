#!/usr/bin/env python3
"""Plain-HTTP relay for the bus tracker hardware.

The ESP32 units cannot do TLS, and Supabase refuses plain HTTP (it 301s to
HTTPS). This sits in the middle: listens on plain HTTP, verifies the device,
and forwards to Supabase over HTTPS.

Because the link to the device is unencrypted, authentication is by HMAC over
the request body with a per-device secret that is NEVER transmitted. An
eavesdropper can read positions but cannot forge them; a monotonic counter
inside the signed body blocks replay.

Wire format — one POST, one header:

    POST /p HTTP/1.1
    X-Sig: <64 hex chars>
    Content-Type: application/json

    {"b":"bus1","d":"esp32-01","c":1234,
     "lat":11.3185,"lng":75.9379,"spd":6.4,"hdg":312}

    X-Sig = HMAC_SHA256(device_secret, exact_raw_body_bytes)

Claiming the bus is handled here, not on the device, so the firmware only ever
has to do this one request type.

Standard library only — nothing to install, nothing to keep patched.
"""
import hashlib
import hmac
import json
import logging
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler

CONF_DIR = os.environ.get('RELAY_CONF', '/etc/bustracker-relay')
STATE_DIR = os.environ.get('RELAY_STATE', '/var/lib/bustracker-relay')
LISTEN_PORT = int(os.environ.get('RELAY_PORT', '8081'))
MAX_BODY = 2048
CLAIM_EVERY = 60  # seconds between re-claims per bus

log = logging.getLogger('relay')


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


class Upstream:
    """Talks to Supabase over HTTPS."""

    def __init__(self, cfg):
        self.url = cfg['supabase_url'].rstrip('/')
        self.key = cfg['supabase_key']
        self._claimed = {}          # bus_id -> last claim time
        self._lock = threading.Lock()

    def _rpc(self, fn, payload, timeout=10):
        req = urllib.request.Request(
            f'{self.url}/rest/v1/rpc/{fn}',
            data=json.dumps(payload).encode(),
            headers={
                'apikey': self.key,
                'Authorization': f'Bearer {self.key}',
                'Content-Type': 'application/json',
            },
            method='POST')
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b'{}')

    def ensure_claim(self, bus_id, device_id):
        """Claim the bus on the device's behalf, at most once a minute."""
        now = time.time()
        with self._lock:
            last = self._claimed.get(bus_id, 0)
            if now - last < CLAIM_EVERY:
                return True
        try:
            res = self._rpc('claim_bus',
                            {'p_bus_id': bus_id, 'p_device_id': device_id})
            if res.get('ok'):
                with self._lock:
                    self._claimed[bus_id] = now
                return True
            log.warning('claim refused for %s: %s', bus_id, res.get('reason'))
            return False
        except Exception as e:
            log.warning('claim_bus failed for %s: %s', bus_id, e)
            return False

    def publish(self, bus_id, device_id, lat, lng, spd, hdg):
        return self._rpc('publish_position', {
            'p_bus_id': bus_id,
            'p_device_id': device_id,
            'p_lat': lat,
            'p_lng': lng,
            'p_speed': spd,
            'p_heading': hdg,
        })


class Counters:
    """Monotonic per-device counters, persisted so a relay restart does not
    re-open the replay window."""

    def __init__(self, path):
        self.path = path
        self.data = load_json(path, {})
        self.lock = threading.Lock()
        self.dirty = False
        threading.Thread(target=self._flusher, daemon=True).start()

    def check_and_set(self, device_id, counter):
        with self.lock:
            if counter <= self.data.get(device_id, -1):
                return False
            self.data[device_id] = counter
            self.dirty = True
            return True

    def _flusher(self):
        while True:
            time.sleep(5)
            with self.lock:
                if not self.dirty:
                    continue
                snapshot = dict(self.data)
                self.dirty = False
            try:
                os.makedirs(os.path.dirname(self.path), exist_ok=True)
                tmp = self.path + '.tmp'
                with open(tmp, 'w') as f:
                    json.dump(snapshot, f)
                os.replace(tmp, self.path)
            except Exception as e:
                log.error('counter flush failed: %s', e)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'   # keep-alive: the device reuses one socket
    server_version = 'bustracker-relay'
    sys_version = ''

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.info('%s %s', self.address_string(), fmt % args)

    def do_GET(self):
        if self.path in ('/health', '/'):
            self._reply(200, {'ok': True, 'service': 'bustracker-relay'})
        else:
            self._reply(404, {'ok': False, 'reason': 'not found'})

    def do_POST(self):
        if self.path not in ('/p', '/publish'):
            return self._reply(404, {'ok': False, 'reason': 'not found'})

        try:
            length = int(self.headers.get('Content-Length', 0))
        except ValueError:
            return self._reply(400, {'ok': False, 'reason': 'bad length'})
        if length <= 0 or length > MAX_BODY:
            return self._reply(400, {'ok': False, 'reason': 'bad length'})

        raw = self.rfile.read(length)
        sig = (self.headers.get('X-Sig') or '').strip().lower()

        try:
            msg = json.loads(raw)
            device_id = str(msg['d'])
            bus_id = str(msg['b'])
            counter = int(msg['c'])
            lat = float(msg['lat'])
            lng = float(msg['lng'])
        except Exception:
            return self._reply(400, {'ok': False, 'reason': 'bad json'})

        dev = DEVICES.get(device_id)
        if not dev:
            log.warning('unknown device %r', device_id)
            return self._reply(403, {'ok': False, 'reason': 'unknown device'})

        # Signature over the exact bytes received.
        expect = hmac.new(dev['secret'].encode(), raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(expect, sig):
            log.warning('bad signature from %s', device_id)
            return self._reply(403, {'ok': False, 'reason': 'bad signature'})

        # A device may only publish as the bus it is bound to.
        if bus_id != dev['bus_id']:
            log.warning('%s tried to publish as %s', device_id, bus_id)
            return self._reply(403, {'ok': False, 'reason': 'wrong bus'})

        if not COUNTERS.check_and_set(device_id, counter):
            return self._reply(409, {'ok': False, 'reason': 'replay'})

        if not (-90 <= lat <= 90 and -180 <= lng <= 180):
            return self._reply(400, {'ok': False, 'reason': 'bad coords'})

        spd = msg.get('spd')
        hdg = msg.get('hdg')
        spd = float(spd) if spd is not None else None
        hdg = float(hdg) if hdg is not None else None

        UP.ensure_claim(bus_id, device_id)
        try:
            res = UP.publish(bus_id, device_id, lat, lng, spd, hdg)
        except urllib.error.HTTPError as e:
            log.error('upstream %s: %s', e.code, e.read()[:200])
            return self._reply(502, {'ok': False, 'reason': 'upstream error'})
        except Exception as e:
            log.error('upstream failed: %s', e)
            return self._reply(502, {'ok': False, 'reason': 'upstream down'})

        # Deliberately terse: every byte here is billed cellular data.
        return self._reply(200, {'ok': bool(res.get('ok'))})


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    logging.basicConfig(
        level=logging.INFO, stream=sys.stdout,
        format='%(asctime)s %(levelname)s %(message)s')

    cfg = load_json(os.path.join(CONF_DIR, 'config.json'), None)
    if not cfg:
        sys.exit(f'missing {CONF_DIR}/config.json')
    devices = load_json(os.path.join(CONF_DIR, 'devices.json'), None)
    if not devices:
        sys.exit(f'missing {CONF_DIR}/devices.json')

    global UP, DEVICES, COUNTERS
    UP = Upstream(cfg)
    DEVICES = devices
    COUNTERS = Counters(os.path.join(STATE_DIR, 'counters.json'))

    log.info('relay listening on 0.0.0.0:%d, %d device(s) configured',
             LISTEN_PORT, len(devices))
    Server(('0.0.0.0', LISTEN_PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()
