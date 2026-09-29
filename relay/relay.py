#!/usr/bin/env python3
"""Plain-HTTP to MQTT relay for the bus tracker hardware.

The ESP32 units cannot do TLS and have no MQTT client, so they do the one thing
a 2G module is reliably good at: a plain HTTP POST. This sits in the middle,
verifies the device, and republishes the fix to MQTT, where the Raspberry Pi
picks it up.

The hardware contract in HARDWARE.md is UNCHANGED. Same URL, same port, same
body, same signature, same responses. Only what happens after verification is
different: this used to forward to Supabase over HTTPS, and now it publishes to
a local MQTT broker.

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

Published as:

    campus/bus/bus1/gps     {"seq":1234,"lat":11.3185,"lng":75.9379,"spd":6.4,"hdg":312}
    campus/bus/bus1/status  "online" | "offline"   (retained)

The device cannot register an MQTT Last Will, so the status topic is driven here
instead: a watchdog marks a bus offline when it stops POSTing.
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
from http.server import BaseHTTPRequestHandler

import paho.mqtt.client as mqtt

CONF_DIR = os.environ.get('RELAY_CONF', '/etc/bustracker-relay')
STATE_DIR = os.environ.get('RELAY_STATE', '/var/lib/bustracker-relay')
LISTEN_PORT = int(os.environ.get('RELAY_PORT', '8081'))
MAX_BODY = 2048

log = logging.getLogger('relay')


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


class MqttUpstream:
    """Publishes verified fixes to the broker.

    Positions go out at QoS 0: a fix that did not make it is not worth retrying,
    because by the time it arrived it would be wrong. Status is QoS 1 and
    retained, so a subscriber that connects late still learns which buses are up.
    """

    def __init__(self, cfg):
        self.host = cfg.get('mqtt_host', '127.0.0.1')
        self.port = int(cfg.get('mqtt_port', 1883))
        self.prefix = cfg.get('topic_prefix', 'campus/bus').rstrip('/')
        self.offline_after = float(cfg.get('offline_after_sec', 30))

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id='bustracker-relay', clean_session=True)
        if cfg.get('mqtt_username'):
            self.client.username_pw_set(cfg['mqtt_username'], cfg.get('mqtt_password', ''))
        self.client.reconnect_delay_set(min_delay=1, max_delay=10)
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.connected = False

        self._last_seen = {}    # bus_id -> monotonic time of last accepted fix
        self._online = set()    # bus_ids currently advertised as online
        self._lock = threading.Lock()

    def start(self):
        try:
            self.client.connect_async(self.host, self.port, keepalive=30)
        except Exception:
            log.exception('mqtt connect failed; paho will retry')
        self.client.loop_start()
        threading.Thread(target=self._watchdog, daemon=True).start()

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        if getattr(reason_code, 'is_failure', False):
            log.error('mqtt connect refused: %s', reason_code)
            return
        self.connected = True
        log.info('mqtt connected to %s:%d', self.host, self.port)
        # Re-advertise after a reconnect: a fresh session has no retained state
        # of ours, and the broker may have been restarted under us.
        with self._lock:
            online = list(self._online)
        for bus_id in online:
            self._publish_status(bus_id, 'online')

    def _on_disconnect(self, client, userdata, flags, reason_code, properties=None):
        self.connected = False
        log.warning('mqtt disconnected: %s', reason_code)

    def _publish_status(self, bus_id, status):
        self.client.publish(f'{self.prefix}/{bus_id}/status', status, qos=1, retain=True)

    def publish(self, bus_id, counter, lat, lng, spd, hdg):
        payload = {'seq': counter, 'lat': lat, 'lng': lng}
        if spd is not None:
            payload['spd'] = spd
        if hdg is not None:
            payload['hdg'] = hdg

        with self._lock:
            self._last_seen[bus_id] = time.monotonic()
            first = bus_id not in self._online
            self._online.add(bus_id)
        if first:
            self._publish_status(bus_id, 'online')
            log.info('bus %s online', bus_id)

        info = self.client.publish(
            f'{self.prefix}/{bus_id}/gps',
            json.dumps(payload, separators=(',', ':')),
            qos=0)
        return info.rc == mqtt.MQTT_ERR_SUCCESS

    def _watchdog(self):
        """Stand in for the MQTT Last Will the device cannot register itself."""
        while True:
            time.sleep(5)
            now = time.monotonic()
            with self._lock:
                gone = [
                    b for b in self._online
                    if now - self._last_seen.get(b, 0) > self.offline_after
                ]
                for b in gone:
                    self._online.discard(b)
            for b in gone:
                self._publish_status(b, 'offline')
                log.info('bus %s offline (no fix for %.0fs)', b, self.offline_after)


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
            self._reply(200, {
                'ok': True,
                'service': 'bustracker-relay',
                'mqtt': UP.connected,
                'buses_online': len(UP._online),
            })
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

        if not UP.connected:
            # Nothing to gain from queueing: by the time the broker is back this
            # fix is history, and the device is already sending a newer one.
            log.warning('dropping fix from %s: broker unreachable', bus_id)
            return self._reply(502, {'ok': False, 'reason': 'upstream down'})

        ok = UP.publish(bus_id, counter, lat, lng, spd, hdg)

        # Deliberately terse: every byte here is billed cellular data.
        return self._reply(200, {'ok': ok})


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
    UP = MqttUpstream(cfg)
    DEVICES = devices
    COUNTERS = Counters(os.path.join(STATE_DIR, 'counters.json'))
    UP.start()

    log.info('relay listening on 0.0.0.0:%d, %d device(s) configured',
             LISTEN_PORT, len(devices))
    Server(('0.0.0.0', LISTEN_PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()
