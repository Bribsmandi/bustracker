# Raspberry Pi backend

Replaces the old cloud stack (relay VM → Supabase → app). All storage,
computation and analytics run on one Pi we own, and there is no server to rent
or keep alive.

The buses publish MQTT directly. That **is** a firmware change from the old HTTP
POST — see `HARDWARE.md`, which has been rewritten for it.

## How the pieces connect

```
ESP32 ──signed MQTT :1883──►┌────────────────────┐
  (2G, no TLS, every 5 s)   │  broker.emqx.io    │
                            │  public, free      │
   tracker app ◄────────────│  nothing to run    │
                            └─────────▲──────────┘
                                      │ one outbound connection
                            ┌─────────┴────────────────────┐
                            │ Raspberry Pi (phone hotspot) │
                            │  verify → process → SQLite   │
                            └──────────────────────────────┘
```

### Why a public broker

Nothing in this system can accept an inbound connection. The buses sit behind
carrier NAT on 2G, and the Pi runs on a phone hotspot — there is no router to
forward a port on and no public IP anywhere. So every party dials *out* to a
common meeting point.

It has to be a *public* broker rather than a managed free tier because the
SIM900A has no TLS, and HiveMQ, EMQX Serverless and the rest accept TLS only.

The consequence is that anyone can publish to these topics, which is why every
fix is signed and verified before the pipeline sees it.

## Topics

`<root>` is `BUS_TOPIC_ROOT`, default `cbt7f3c9e21b` — unguessable so the buses
do not collide with the thousands of others on this broker.

| Topic | Published by | Read by | Retained |
|---|---|---|---|
| `<root>/bus/{id}/gps` | bus, signed | Pi | no |
| `<root>/bus/{id}/status` | bus + its Last Will | Pi | yes |
| `<root>/live/buses` | Pi | app | **yes** |
| `<root>/live/stop/{stop_id}` | Pi | app | **yes** |
| `<root>/live/config` | Pi | app | **yes** |

Everything the app needs is retained, so opening the app delivers current state
on subscribe — no request/response round trip, no "fetch then subscribe" race,
and a timetable fix reaches phones without an app release.

Each bus registers an MQTT Last Will, so the broker announces it offline the
moment the connection dies — no polling, no timeout guesswork.

## Verifying signatures

The Pi needs the per-device secrets, in the same `devices.json` format the relay
used:

```bash
sudo cp /opt/bustracker/relay/devices.json /etc/bustracker/devices.json
sudo chmod 600 /etc/bustracker/devices.json
```

Without them **every fix is rejected** and the log says so. That is deliberate:
failing closed is the only safe default when the transport is a public broker.

`BUS_REQUIRE_SIGNATURE=0` disables the check for local replay against a private
broker. Never set it in production.

## Install

One command, once the repository is cloned to `/opt/bustracker`:

```bash
sudo /opt/bustracker/pi/scripts/deploy_pi.sh
```

It installs the dependencies, builds the venv, **runs the test suite and stops
if it fails**, installs the services and verifies the broker connection. Re-run
it to upgrade; it keeps your `server.env` and never touches the database.

The defaults point at the public broker and need no credentials, so
`server.env` usually needs no editing at all. What it does need is the device
secrets — see above.

<details>
<summary>Manual steps, if you prefer</summary>

```bash
sudo useradd -r -s /usr/sbin/nologin bustracker
sudo mkdir -p /opt/bustracker /var/lib/bustracker /etc/bustracker
sudo rsync -a --exclude .venv ./ /opt/bustracker/

cd /opt/bustracker/pi/server
sudo python3 -m venv .venv
sudo .venv/bin/pip install -e .

sudo cp /opt/bustracker/pi/systemd/server.env.example /etc/bustracker/server.env
sudo chmod 600 /etc/bustracker/server.env
sudo cp /opt/bustracker/relay/devices.json /etc/bustracker/devices.json

sudo cp /opt/bustracker/pi/systemd/busserver.service /etc/systemd/system/
sudo cp /opt/bustracker/pi/systemd/bustracker-backup.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now busserver.service bustracker-backup.timer
```

</details>

The Pi does **not** need Mosquitto installed, and needs no inbound ports, no
tunnel and no domain. [`../relay/`](../relay/) and [`../broker/`](../broker/)
are not used by this design; they are kept in case the buses ever go back to
HTTP with a self-hosted broker.

## Verify

```bash
curl -s localhost:8000/health | python3 -m json.tool
```

`mqtt_connected: true` means the outbound link to the broker is up.

Drive a bus without hardware. This signs exactly as the firmware does, so the
server cannot tell the difference:

```bash
pi/scripts/replay_trace.py --bus bus1 --route mbh_to_east \
  --devices-file relay/devices.json
```

Watch what the server publishes back:

```bash
mosquitto_sub -h broker.emqx.io -t 'cbt7f3c9e21b/live/buses' -v
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
**5 s** fix interval in `HARDWARE.md` §7.1, not the 1 Hz the design report
assumed. Everything is overridable by environment variable.

| Setting | Default | Why |
|---|---|---|
| `BUS_LIVE_MAX_AGE` | 12 s | One missed 5 s fix is normal on 2G |
| `BUS_DELAYED_MAX_AGE` | 30 s | Two missed fixes is worth flagging |
| `BUS_STALE_MAX_AGE` | 120 s | A 2G reconnect can legitimately take a minute |
| `BUS_POS_SMOOTHING` | 0.2 | Fixes 5 s apart are genuinely different positions |
| `BUS_LIVE_MIN_INTERVAL` | 1 s | Floor on publish rate when state changes |
| `BUS_LIVE_MAX_INTERVAL` | 10 s | Republish even when idle, so age/status propagate |
| `BUS_TOPIC_ROOT` | `cbt7f3c9e21b` | Must match the buses and the app |
| `BUS_REQUIRE_SIGNATURE` | `1` | Fail closed; only disable for local replay |

Publishing is change-driven rather than a fixed 1 Hz stream — students pay for
every byte their phone receives.

## Known gaps

- **Device secrets are in git history.** `relay/devices.json` holds all six live
  HMAC secrets, and `HARDWARE.md` §5/§8 say they should never be committed. They
  are what stops anyone forging a bus position, so they should be rotated before
  the system is relied on. Deliberately deferred as a prototype decision.
- **Public broker, no TLS.** The SIM900A cannot do TLS and managed free tiers
  are TLS-only. Forging a position is blocked by the HMAC, but anyone can read
  the topics and the broker offers no SLA. Acceptable for a demo; move to a
  private broker before anyone depends on it.
- **GPS quality filtering is inert.** The firmware sends no `sats`/`hdop`, so
  those validation gates no-op. The bbox and jump checks still apply.
- **Push notifications are untested.** Code is complete but `BUS_PUSH_ENABLED`
  defaults off and no FCM project is wired up.
- **Never run on real hardware.** Verified end to end against the real public
  broker from a laptop, but not yet on a Pi or with an ESP32.
- **The firmware does not speak MQTT yet.** Until it does, the buses cannot
  reach this. `pi/scripts/replay_trace.py` stands in for them.
