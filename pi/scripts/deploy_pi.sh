#!/usr/bin/env bash
# One-shot setup for the Raspberry Pi: the processor and API service.
#
# Safe to re-run: use it for the first install and for later upgrades. It keeps
# an existing server.env and never touches the database.
#
#   sudo ./deploy_pi.sh
#
# The Pi needs no broker of its own and no inbound ports. It dials out to the
# broker on the VM, which is why BUS_MQTT_HOST must be the VM, not localhost.
set -euo pipefail

REPO=${REPO:-/opt/bustracker}
SERVER="$REPO/pi/server"
ENV_FILE=${ENV_FILE:-/etc/bustracker/server.env}
STATE=${STATE:-/var/lib/bustracker}

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo" >&2
  exit 1
fi
if [[ ! -d $SERVER ]]; then
  echo "server not found at $SERVER" >&2
  echo "clone it first:  git clone -b pi-backend <url> $REPO" >&2
  exit 1
fi

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- packages
say "Installing packages"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip sqlite3 curl

# ---------------------------------------------------------------- clock
# The server stamps arrival times itself, so a wrong clock corrupts every age,
# status and ETA in the system.
say "Checking the clock"
timedatectl set-ntp true 2>/dev/null || true
timedatectl | sed 's/^/  /'

# ---------------------------------------------------------------- venv
say "Installing the Python environment"
id -u bustracker >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin bustracker
mkdir -p "$STATE" /etc/bustracker
chown bustracker:bustracker "$STATE"

if [[ ! -d $SERVER/.venv ]]; then
  python3 -m venv "$SERVER/.venv"
fi
"$SERVER/.venv/bin/pip" install -q --upgrade pip
"$SERVER/.venv/bin/pip" install -q -e "$SERVER"
echo "  installed"

# ---------------------------------------------------------------- self-test
say "Running the test suite"
"$SERVER/.venv/bin/pip" install -q -e "$SERVER[dev]"
# Run from the package root: pyproject sets testpaths and pythonpath relative to
# it. Piping to tail would mask the exit status, so check it directly.
if ( cd "$SERVER" && ./.venv/bin/python -m pytest tests -q ); then
  echo "  tests passed"
else
  echo "  tests FAILED -- stopping before this goes live" >&2
  exit 1
fi

# ---------------------------------------------------------------- env
say "Environment file"
if [[ -f $ENV_FILE ]]; then
  echo "  $ENV_FILE exists, leaving it alone"
else
  install -m 600 "$REPO/pi/systemd/server.env.example" "$ENV_FILE"
  echo "  created $ENV_FILE from the example"
fi

if grep -q 'change-me' "$ENV_FILE"; then
  cat >&2 <<'WARN'

  !! BUS_MQTT_PASSWORD is still the placeholder.
     Edit the file, set BUS_MQTT_HOST to the VM and BUS_MQTT_PASSWORD to the
     'processor' password that deploy_vm.sh printed, then re-run this script:

       sudo nano /etc/bustracker/server.env

WARN
  exit 1
fi

# ---------------------------------------------------------------- service
say "Installing services"
install -m 644 "$REPO/pi/systemd/busserver.service" /etc/systemd/system/
install -m 644 "$REPO/pi/systemd/bustracker-backup.service" /etc/systemd/system/
install -m 644 "$REPO/pi/systemd/bustracker-backup.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable -q busserver.service
systemctl restart busserver.service
systemctl enable -q --now bustracker-backup.timer
sleep 3

# ---------------------------------------------------------------- verify
say "Verifying"
if ! systemctl is-active --quiet busserver; then
  journalctl -u busserver -n 30 --no-pager
  exit 1
fi

health=$(curl -s --max-time 5 http://localhost:8000/health || true)
echo "  /health: $health"

if [[ $health == *'"mqtt_connected": true'* || $health == *'"mqtt_connected":true'* ]]; then
  echo "  OK: connected to the broker on the VM"
else
  cat >&2 <<WARN

  FAILED: the service is up but not connected to the broker.

  Most likely the broker port is not reachable from here. Check, in order:

    nc -zv \$(grep BUS_MQTT_HOST $ENV_FILE | cut -d= -f2) 1883
    grep BUS_MQTT $ENV_FILE
    journalctl -u busserver -n 30 --no-pager

  If nc fails, open 1883 in the VM's CLOUD firewall, not just ufw.

WARN
  exit 1
fi

say "Done"
cat <<'SUMMARY'

The Pi is running. Useful commands:

  systemctl status busserver
  journalctl -u busserver -f
  curl -s localhost:8000/health | python3 -m json.tool

To upgrade later:

  cd /opt/bustracker && sudo git pull && sudo pi/scripts/deploy_pi.sh

SUMMARY
