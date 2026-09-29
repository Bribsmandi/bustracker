#!/usr/bin/env bash
# Run the bus server on a laptop, with no install and no systemd.
#
#   ./pi/scripts/run_local.sh
#
# Same code and same broker as the Pi, so the phone apps cannot tell the
# difference. Use it to demo before the Pi is set up, or to watch the log while
# debugging. Ctrl-C stops it and marks the server offline in the app.
set -euo pipefail

cd "$(dirname "$0")/../.."
SERVER=pi/server

if [[ ! -d $SERVER/.venv ]]; then
  echo "== creating the virtualenv (first run only)"
  python3 -m venv "$SERVER/.venv"
  "$SERVER/.venv/bin/pip" install -q --upgrade pip
  "$SERVER/.venv/bin/pip" install -q -e "$SERVER"
fi

# Device secrets: the server rejects every unsigned fix, so without these
# nothing appears and the reason is only in the log.
export BUS_SECRETS=${BUS_SECRETS:-$PWD/relay/devices.json}
if [[ ! -f $BUS_SECRETS ]]; then
  echo "no device secrets at $BUS_SECRETS" >&2
  exit 1
fi

export BUS_DATA_DIR=${BUS_DATA_DIR:-$PWD/data}
export BUS_DB_PATH=${BUS_DB_PATH:-$PWD/.local-bus.db}
export BUS_MQTT_HOST=${BUS_MQTT_HOST:-broker.emqx.io}
export BUS_MQTT_PORT=${BUS_MQTT_PORT:-1883}
export BUS_MQTT_USERNAME=${BUS_MQTT_USERNAME:-}
export BUS_MQTT_PASSWORD=${BUS_MQTT_PASSWORD:-}
export BUS_TOPIC_ROOT=${BUS_TOPIC_ROOT:-cbt7f3c9e21b}

cat <<INFO

  broker    $BUS_MQTT_HOST:$BUS_MQTT_PORT
  topics    $BUS_TOPIC_ROOT/
  secrets   $BUS_SECRETS
  database  $BUS_DB_PATH

  The apps must use the same topic root. Ctrl-C to stop.

INFO

exec "$SERVER/.venv/bin/uvicorn" app.main:app \
  --host 127.0.0.1 --port 8000 --app-dir "$SERVER" --log-level info
