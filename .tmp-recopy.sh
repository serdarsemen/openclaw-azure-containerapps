#!/bin/bash
SRC=/mnt/c/app/openclaw-azure-containerapps/openclaw-data
DST=/home/serdar/.openclaw-data

echo "=== Copying openclaw.json ==="
cp -v "$SRC/openclaw.json" "$DST/openclaw.json" && echo "OK"

echo "=== Copying .md files ==="
find "$SRC" -name "*.md" | while IFS= read -r f; do
  rel="${f#${SRC}/}"
  dir=$(dirname "$rel")
  mkdir -p "$DST/$dir"
  cp -v "$f" "$DST/$rel"
done

echo "=== Done ==="
