#!/usr/bin/env bash
# One-shot setup for the VM side: Mosquitto broker + the HTTP-to-MQTT relay.
#
# Safe to re-run. It never overwrites credentials that already exist, and it
# backs up the old relay before replacing it, so a failed upgrade can be undone.
#
#   sudo ./deploy_vm.sh
#
# At the end it prints the three passwords and the exact settings to paste into
# the Pi's /etc/bustracker/server.env and the apps' build commands.
set -euo pipefail

REPO=${REPO:-/opt/bustracker}
RELAY_DIR=${RELAY_DIR:-/opt/bustracker-relay}
RELAY_CONF=${RELAY_CONF:-/etc/bustracker-relay}
RELAY_STATE=${RELAY_STATE:-/var/lib/bustracker-relay}
PASSWD=/etc/mosquitto/passwd
ACL=/etc/mosquitto/acl

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi
if [[ ! -d $REPO ]]; then
  echo "repository not found at $REPO" >&2
  echo "clone it first:  git clone -b pi-backend <url> $REPO" >&2
  exit 1
fi

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
newpw() { head -c 18 /dev/urandom | base64 | tr -d '/+='; }

# ---------------------------------------------------------------- packages
say "Installing packages"
apt-get update -qq
apt-get install -y -qq mosquitto mosquitto-clients python3 curl
# paho: prefer the distro package, fall back to pip.
if ! python3 -c 'import paho.mqtt' 2>/dev/null; then
  apt-get install -y -qq python3-paho-mqtt 2>/dev/null \
    || pip3 install --break-system-packages -q paho-mqtt
fi
python3 -c 'import paho.mqtt' || { echo "paho-mqtt missing" >&2; exit 1; }

# ---------------------------------------------------------------- broker
say "Configuring Mosquitto"
install -m 644 "$REPO/broker/campus.conf" /etc/mosquitto/conf.d/campus.conf
if [[ -f $ACL ]]; then
  echo "  $ACL exists, leaving it alone"
else
  install -m 644 "$REPO/broker/acl.example" "$ACL"
fi

# Credentials. Existing ones are kept: rotating them would break a Pi or an app
# already configured against them.
declare -A PW
for role in relay processor app; do
  if [[ -f $PASSWD ]] && grep -q "^${role}:" "$PASSWD"; then
    PW[$role]='(unchanged - already set)'
    echo "  $role: already exists, keeping it"
  else
    p=$(newpw)
    if [[ -f $PASSWD ]]; then
      mosquitto_passwd -b "$PASSWD" "$role" "$p"
    else
      mosquitto_passwd -c -b "$PASSWD" "$role" "$p"
    fi
    PW[$role]=$p
    echo "  $role: created"
  fi
done
chown mosquitto:mosquitto "$PASSWD"
chmod 600 "$PASSWD"

systemctl enable -q mosquitto
systemctl restart mosquitto
sleep 1
systemctl is-active --quiet mosquitto || { journalctl -u mosquitto -n 20 --no-pager; exit 1; }
echo "  mosquitto running"

# ---------------------------------------------------------------- relay
say "Deploying the relay"
id -u bustracker >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin bustracker
mkdir -p "$RELAY_DIR" "$RELAY_CONF" "$RELAY_STATE"

# Keep a copy of whatever is running now, in case this upgrade has to be undone.
if [[ -f $RELAY_DIR/relay.py ]]; then
  cp -a "$RELAY_DIR/relay.py" "$RELAY_DIR/relay.py.bak.$(date +%Y%m%d-%H%M%S)"
  echo "  backed up the previous relay.py"
fi
install -m 755 "$REPO/relay/relay.py" "$RELAY_DIR/relay.py"

# devices.json carries the per-bus signing secrets; never clobber it.
if [[ -f $RELAY_CONF/devices.json ]]; then
  echo "  devices.json exists, leaving it alone"
else
  install -m 640 "$REPO/relay/devices.json" "$RELAY_CONF/devices.json"
  echo "  devices.json installed from the repo -- ROTATE THESE SECRETS"
fi
chown root:bustracker "$RELAY_CONF/devices.json"
chmod 640 "$RELAY_CONF/devices.json"

# config.json is rewritten only when it still lacks a real broker password.
relay_pw=${PW[relay]}
if [[ -f $RELAY_CONF/config.json ]] && ! grep -q 'CHANGE_ME\|supabase' "$RELAY_CONF/config.json"; then
  echo "  config.json already configured, leaving it alone"
else
  if [[ $relay_pw == '(unchanged'* ]]; then
    echo "  !! config.json needs the existing 'relay' broker password" >&2
    echo "     edit $RELAY_CONF/config.json by hand, then re-run" >&2
    relay_pw='PUT_THE_EXISTING_RELAY_PASSWORD_HERE'
  fi
  cat > "$RELAY_CONF/config.json" <<JSON
{
  "mqtt_host": "127.0.0.1",
  "mqtt_port": 1883,
  "mqtt_username": "relay",
  "mqtt_password": "$relay_pw",
  "topic_prefix": "campus/bus",
  "offline_after_sec": 30
}
JSON
  chmod 600 "$RELAY_CONF/config.json"
  echo "  config.json written"
fi
chown -R bustracker:bustracker "$RELAY_STATE"

install -m 644 "$REPO/relay/bustracker-relay.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q bustracker-relay
systemctl restart bustracker-relay
sleep 2

# ---------------------------------------------------------------- firewall
say "Opening ports"
if command -v ufw >/dev/null && ufw status | grep -q active; then
  ufw allow 1883/tcp >/dev/null
  ufw allow 9001/tcp >/dev/null
  ufw allow 8081/tcp >/dev/null
  echo "  ufw: 1883, 9001, 8081 allowed"
else
  echo "  ufw inactive or absent -- nothing to do locally"
fi
echo "  NOTE: also open 1883, 9001 and 8081 in your cloud provider's firewall."
echo "        ufw alone is not enough on AWS, Oracle, GCP or Azure."

# ---------------------------------------------------------------- verify
say "Verifying"
health=$(curl -s --max-time 5 http://localhost:8081/health || true)
echo "  relay /health: $health"
if [[ $health == *'"mqtt": true'* ]]; then
  echo "  OK: the relay is connected to the broker"
else
  echo "  FAILED: the relay is not connected to the broker" >&2
  echo "  check the password in $RELAY_CONF/config.json, then:" >&2
  echo "    journalctl -u bustracker-relay -n 30 --no-pager" >&2
  exit 1
fi

# ---------------------------------------------------------------- summary
say "Done. Settings for the rest of the system"
host=$(hostname -f 2>/dev/null || hostname)
cat <<SUMMARY

Broker host: $host

Passwords (shown once; '(unchanged)' means it was already set and is not
recoverable -- re-issue with: sudo mosquitto_passwd $PASSWD <role>):

  relay      ${PW[relay]}
  processor  ${PW[processor]}
  app        ${PW[app]}

On the Raspberry Pi, put this in /etc/bustracker/server.env:

  BUS_MQTT_HOST=$host
  BUS_MQTT_PORT=1883
  BUS_MQTT_USERNAME=processor
  BUS_MQTT_PASSWORD=${PW[processor]}

Build the tracker app with:

  flutter build apk --release \\
    --dart-define=BUS_MQTT_HOST=$host \\
    --dart-define=BUS_MQTT_PASSWORD=${PW[app]}

Watch what the buses are sending:

  mosquitto_sub -h localhost -u processor -P '${PW[processor]}' -t 'campus/bus/+/gps' -v

SUMMARY
