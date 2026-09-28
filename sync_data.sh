#!/usr/bin/env bash
# Copies the canonical data/ JSON files into each Flutter app's assets.
# Run this after editing anything in data/ (e.g. filling stop coordinates).
set -euo pipefail
cd "$(dirname "$0")"

cp data/stops.json data/buses.json data/routes.json data/schedule.json data/basemap.json tracker/assets/data/
cp data/stops.json data/buses.json data/routes.json publisher/assets/data/

echo "Synced data/ -> tracker/assets/data and publisher/assets/data"
