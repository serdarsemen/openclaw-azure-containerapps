#!/bin/sh
set -eu
umask 077

container="${1:-openclaw}"
output_dir="${2:-$HOME/.openclaw-data/logs/restarts}"
pid_file="$output_dir/monitor.pid"
mkdir -p "$output_dir"

if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  exit 0
fi
echo "$$" > "$pid_file"
trap 'rm -f "$pid_file"' EXIT

docker events \
  --filter "container=$container" \
  --filter "event=die" \
  --filter "event=restart" \
  --format '{{json .}}' |
while IFS= read -r event; do
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$output_dir/$stamp"
  mkdir -p "$target"
  printf '%s\n' "$event" > "$target/event.json"
  docker inspect "$container" > "$target/inspect.json" 2>&1 || true
  docker stats --no-stream "$container" > "$target/stats.txt" 2>&1 || true
  docker logs --tail 250 "$container" > "$target/container.log" 2>&1 || true
  if [ -f /diagnostics/gateway-restart-request.json ]; then
    cp /diagnostics/gateway-restart-request.json "$target/gateway-restart-request.json" || true
  fi
  docker exec "$container" node openclaw.mjs cron status --json \
    > "$target/cron-status.json" 2>&1 || true
  docker exec "$container" sh -lc 'ps -eo pid,etime,pcpu,pmem,args --sort=-pcpu | head -40' \
    > "$target/processes.txt" 2>&1 || true
done
