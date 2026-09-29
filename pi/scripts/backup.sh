#!/usr/bin/env bash
# Nightly backup of the SQLite database to a USB drive.
#
# Uses the sqlite3 .backup command rather than cp: the server is running in WAL
# mode and copying the file underneath it can capture a torn state.
set -euo pipefail

DB=${BUS_DB_PATH:-/var/lib/bustracker/bus.db}
DEST=${BUS_BACKUP_DIR:-/media/backup/bustracker}
KEEP=${BUS_BACKUP_KEEP:-30}

if [[ ! -f $DB ]]; then
  echo "no database at $DB" >&2
  exit 1
fi
if [[ ! -d $DEST ]]; then
  echo "backup target $DEST is not mounted" >&2
  exit 1
fi

stamp=$(date +%Y%m%d-%H%M%S)
out="$DEST/bus-$stamp.db"

sqlite3 "$DB" ".backup '$out'"
gzip -f "$out"
echo "wrote $out.gz"

# Keep the most recent KEEP backups.
ls -1t "$DEST"/bus-*.db.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --
