# Raspberry Pi backend

Replaces the old cloud stack (relay VM → Supabase → app). All storage,
computation and analytics now run on one Pi we own. The hardware in the buses is
**unchanged** — `HARDWARE.md` is still accurate as written.

## How the pieces connect

```
ESP32 ──HTTP POST + X-Sig──► relay.py ──►┌──────────────────────┐
  (2G, no TLS, 5 s)          (public VM) │ Mosquitto (public VM)│
                                         │  campus/bus/+/gps    │◄──┐ subscribe
     mobile app ◄────MQTT / WSS──────────│  campus/live/#       │───┘ publish
                                         └──────────────────────┘
                                                    ▲ one outbound connection
                                              ┌─────┴──────────────────────┐
                                              │ Raspberry Pi (classroom)   │
                                              │  processor → SQLite        │
                                              │  FastAPI (REST, admin)     │
                                              └────────────────────────────┘
```

### Why the broker is not on the Pi

The Pi sits behind campus NAT with no public IP and no port forwarding, so
**nothing on the internet can open a connection to it**. An MQTT connection needs
one side listening and reachable. So the broker lives on the VM, and the Pi
connects *outward* to it — which NAT permits. The phones connect to the same
broker, which is the other reason it has to be public.

The Pi is a client in both directions: it subscribes to raw fixes and publishes
the processed snapshot back.

### Why the relay survived

The ESP32 units run SIM900A — 2G, **no TLS, no MQTT client, no WebSocket**. They
cannot speak to a broker directly. `relay.py` already existed to bridge that gap
(plain HTTP in, something else out), so it keeps its job and only its upstream
changed: Supabase-over-HTTPS became an MQTT publish. Nothing in the buses had to
be touched, and the SIM module's limitations stopped mattering.

## Topics

| Topic | Published by | Read by | Retained |
|---|---|---|---|
| `campus/bus/{id}/gps` | relay | Pi | no |
| `campus/bus/{id}/status` | relay watchdog | Pi | yes |
| `campus/live/buses` | Pi | app | **yes** |
| `campus/live/stop/{stop_id}` | Pi | app | **yes** |
| `campus/live/config` | Pi | app | **yes** |

Everything the app needs is retained, so opening the app delivers current state
on subscribe — no request/response round trip, no "fetch then subscribe" race,
and a timetable fix reaches phones without an app release.

The device cannot register an MQTT Last Will, so the relay publishes `offline` on
its behalf when a bus stops POSTing.

## Install

```bash
sudo useradd -r -s /usr/sbin/nologin bustracker
sudo mkdir -p /opt/bustracker /var/lib/bustracker /etc/bustracker
sudo rsync -a --exclude .venv ./ /opt/bustracker/

cd /opt/bustracker/pi/server
sudo python3 -m venv .venv
sudo .venv/bin/pip install -e .

sudo cp /opt/bustracker/pi/systemd/server.env.example /etc/bustracker/server.env
sudo chmod 600 /etc/bustracker/server.env    # holds the broker password
sudo nano /etc/bustracker/server.env         # set BUS_MQTT_HOST / PASSWORD

sudo cp /opt/bustracker/pi/systemd/busserver.service /etc/systemd/system/
sudo cp /opt/bustracker/pi/systemd/bustracker-backup.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now busserver.service bustracker-backup.timer
```

The Pi does **not** need Mosquitto installed. See [`../broker/`](../broker/) for
the VM side and [`../relay/`](../relay/) for the HTTP→MQTT relay.

## Verify

```bash
curl -s localhost:8000/health | python3 -m json.tool
```

`mqtt_connected: true` means the outbound link to the VM broker is up.

Drive a bus without hardware, through the real signed-HTTP path:

```bash
relay/simulate_device.py --device esp32-01 --devices-file relay/devices.json \
  --route mbh_to_east
```

Or inject straight into the pipeline, skipping relay and broker:

```bash
pi/scripts/replay_trace.py --bus bus1 --route mbh_to_east --host <broker> --user relay
```

## Exposing the REST API

The live map does not need this — it comes over MQTT. The API serves what
pub/sub is the wrong shape for: trip planning, analytics and admin.

**Tailscale Funnel** (free, no domain, stable hostname):

```bash
sudo tailscale funnel --bg 8000
```

**Cloudflare Tunnel** is the alternative if you buy a domain (~$10/yr); see
[`cloudflared/config.example.yml`](cloudflared/config.example.yml). Note that
`.web` is not a real TLD — it was never delegated by ICANN and will not resolve.

Either way the Pi needs no inbound ports and no router changes.

## Tuning notes

Defaults in [`server/app/config.py`](server/app/config.py) are sized for the
**5 s** fix interval in `HARDWARE.md` §6.1, not the 1 Hz the design report
assumed. Everything is overridable by environment variable.

| Setting | Default | Why |
|---|---|---|
| `BUS_LIVE_MAX_AGE` | 12 s | One missed 5 s fix is normal on 2G |
| `BUS_DELAYED_MAX_AGE` | 30 s | Two missed fixes is worth flagging |
| `BUS_STALE_MAX_AGE` | 120 s | A 2G reconnect can legitimately take a minute |
| `BUS_POS_SMOOTHING` | 0.2 | Fixes 5 s apart are genuinely different positions |
| `BUS_LIVE_MIN_INTERVAL` | 1 s | Floor on publish rate when state changes |
| `BUS_LIVE_MAX_INTERVAL` | 10 s | Republish even when idle, so age/status propagate |

Publishing is change-driven rather than a fixed 1 Hz stream — students pay for
every byte their phone receives.

## Known gaps

- **Device secrets are in git history.** `relay/devices.json` holds all six live
  HMAC secrets, and `HARDWARE.md` §5/§8 say they should never be committed. They
  are what stops anyone forging a bus position, so they should be rotated before
  the system is relied on. Deliberately deferred as a prototype decision.
- **No TLS anywhere.** The bus→relay leg cannot have it (SIM900A), and the
  broker legs currently do not. Forging positions is still blocked by the HMAC,
  but credentials and positions are readable in transit. See
  [`../broker/README.md`](../broker/README.md) for the upgrade.
- **GPS quality filtering is inert.** The firmware sends no `sats`/`hdop`, so
  those validation gates no-op. The bbox and jump checks still apply.
- **Push notifications are untested.** Code is complete but `BUS_PUSH_ENABLED`
  defaults off and no FCM project is wired up.
- **Tracker/publisher Flutter apps are unchanged** and still point at Supabase.
  They need their data layer swapped to MQTT.
