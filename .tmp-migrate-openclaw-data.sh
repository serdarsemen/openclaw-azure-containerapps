#!/usr/bin/env bash
set -euo pipefail

SRC="/mnt/c/app/openclaw-azure-containerapps/openclaw-data"
DST="$HOME/.openclaw-data"

echo "SOURCE=$SRC"
echo "DEST=$DST"

if [ ! -d "$SRC" ]; then
  echo "ERROR: source directory not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DST"

if command -v rsync >/dev/null 2>&1; then
  echo "COPY_METHOD=rsync"
  rsync -a --delete-after "$SRC"/ "$DST"/
else
  echo "COPY_METHOD=cp -a"
  cp -a "$SRC"/. "$DST"/
fi

chmod -R go-w "$DST" || true
[ -d "$DST/extensions/token-optimizer-openclaw" ] && chmod 700 "$DST/extensions/token-optimizer-openclaw" || true
[ -d "$DST/agents/researcher/agent" ] && chmod 700 "$DST/agents/researcher/agent" || true

FILES=$(find "$DST" -type f | wc -l)
DIRS=$(find "$DST" -type d | wc -l)
echo "FILES=$FILES"
echo "DIRS=$DIRS"

if [ -e "$DST/extensions/token-optimizer-openclaw" ]; then
  stat -c "MODE extensions/token-optimizer-openclaw=%a" "$DST/extensions/token-optimizer-openclaw"
fi
if [ -e "$DST/agents/researcher/agent" ]; then
  stat -c "MODE agents/researcher/agent=%a" "$DST/agents/researcher/agent"
fi

echo "MIGRATION_STATUS=success"
