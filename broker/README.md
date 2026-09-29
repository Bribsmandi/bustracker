# MQTT broker (public VM)

Runs on the same box as `relay.py` — the one already reachable at
`recverse.ibinujaleel.dev`. It is the hub every other part connects to.

## Why it is here and not on the Pi

The Pi sits behind campus NAT with no public IP and no port forwarding, so
nothing on the internet can open a connection *to* it. An MQTT connection needs
one side listening and reachable. So the broker lives on the VM, and the Pi
connects **outward** to it as a client — which NAT allows.

The phones connect here too, which is the other reason it must be public.

## Topics

| Topic | Published by | Read by | QoS | Retained |
|---|---|---|---|---|
| `campus/bus/{id}/gps` | relay | Pi | 0 | no |
| `campus/bus/{id}/status` | relay | Pi | 1 | **yes** |
| `campus/live/buses` | Pi | app | 0 | **yes** |
| `campus/live/stop/{stop_id}` | Pi | app | 0 | **yes** |

`campus/live/*` is retained on purpose: a phone that opens the app gets the
latest snapshot immediately on subscribe, with no request/response round trip
and no "fetch then subscribe" race.

Positions are QoS 0 — a fix that needs retrying is already too old to be worth
delivering.

## Setup

One command, once the repository is cloned to `/opt/bustracker`:

```bash
sudo /opt/bustracker/broker/deploy_vm.sh
```

It installs Mosquitto and the relay, creates the three credentials, opens the
local firewall, verifies the relay reached the broker, and prints the settings
to paste into the Pi and the app builds. Safe to re-run: existing credentials,
`devices.json` and a configured `config.json` are left alone, and the previous
`relay.py` is backed up before being replaced.

<details>
<summary>Manual steps, if you prefer</summary>

```bash
sudo apt install mosquitto mosquitto-clients
sudo cp campus.conf /etc/mosquitto/conf.d/campus.conf
sudo cp acl.example /etc/mosquitto/acl
```

Create the three credentials (`-c` creates the file, so only use it once):

```bash
sudo mosquitto_passwd -c /etc/mosquitto/passwd relay
sudo mosquitto_passwd /etc/mosquitto/passwd processor
sudo mosquitto_passwd /etc/mosquitto/passwd app
sudo chmod 600 /etc/mosquitto/passwd
sudo chown mosquitto:mosquitto /etc/mosquitto/passwd
sudo systemctl restart mosquitto
```

Open the ports on the VM firewall / cloud security group:

```bash
sudo ufw allow 1883/tcp   # Pi, and native-MQTT mobile clients
sudo ufw allow 9001/tcp   # WebSocket clients
```

</details>

Put the `relay` credential into `/etc/bustracker-relay/config.json`, and the
`processor` one into the Pi's `/etc/bustracker/server.env`.

## Check it works

```bash
# watch raw fixes arriving from the buses
mosquitto_sub -h localhost -u processor -P "$PW" -t 'campus/bus/+/gps' -v

# watch the processed snapshot the app consumes
mosquitto_sub -h localhost -u app -P "$PW" -t 'campus/live/#' -v
```

## Prototype limitation — no TLS

This configuration is plaintext. Credentials and positions are readable by
anyone who can observe the traffic, and the `app` credential ships inside the
mobile app, so treat it as public.

What this does *not* allow, even so: forging a bus position. Those are signed by
the device with a per-device HMAC secret that the relay verifies before
publishing, so a stolen broker credential cannot inject a fake bus.

Before any non-prototype use, add TLS on 8883/443 with a Let's Encrypt
certificate (`certfile`/`keyfile` in a second listener) and move the Pi and the
app onto it. Nothing else in the design has to change.
