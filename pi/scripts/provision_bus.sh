#!/usr/bin/env bash
# Create or rotate one bus's broker credential and print what the ESP32 needs.
#
# The password is shown once and not stored anywhere else: mosquitto_passwd keeps
# only a hash. If it is lost, run this again to issue a new one.
set -euo pipefail

BUS_ID=${1:-}
PASSWD_FILE=${PASSWD_FILE:-/etc/mosquitto/passwd}
ACL_FILE=${ACL_FILE:-/etc/mosquitto/acl}

if [[ -z $BUS_ID ]]; then
  echo "usage: $0 <bus-id>    (bus1 bus2 bus3 bus4 ac_mbh ac_lh)" >&2
  exit 1
fi

if ! command -v mosquitto_passwd >/dev/null; then
  echo "mosquitto_passwd not found; install mosquitto-clients" >&2
  exit 1
fi

secret=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)

if [[ -f $PASSWD_FILE ]]; then
  mosquitto_passwd -b "$PASSWD_FILE" "$BUS_ID" "$secret"
else
  mosquitto_passwd -c -b "$PASSWD_FILE" "$BUS_ID" "$secret"
fi
chown mosquitto:mosquitto "$PASSWD_FILE"
chmod 600 "$PASSWD_FILE"

if ! grep -q "^user $BUS_ID$" "$ACL_FILE" 2>/dev/null; then
  printf '\nuser %s\ntopic write campus/bus/%s/#\n' "$BUS_ID" "$BUS_ID" >> "$ACL_FILE"
  echo "added an ACL block for $BUS_ID"
fi

systemctl reload-or-restart mosquitto

cat <<INFO

Provisioned $BUS_ID. Put these in the firmware configuration:

  MQTT URI       wss://mqtt.<your-domain>/
  username       $BUS_ID
  password       $secret
  publish topic  campus/bus/$BUS_ID/gps
  status topic   campus/bus/$BUS_ID/status   (Last Will "offline", retained, QoS 1)

This password is not recoverable. Re-run this script to issue a new one.
INFO
