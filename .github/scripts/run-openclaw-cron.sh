#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-openclaw-cron.sh — one-shot OpenClaw cron driver for GitHub Actions
#
# OpenClaw's cron scheduler runs *inside* the Gateway process, so there is no
# long-lived daemon in CI. This script reproduces a single scheduler "tick":
#
#   1. Start the Gateway in the background (loopback bind, no respawn).
#   2. Wait until the Gateway answers /healthz.
#   3. Fire every enabled cron job that is currently due, blocking on each.
#   4. Gracefully stop the Gateway so it flushes SQLite/state to disk.
#
# The surrounding workflow restores/saves $HOME/.openclaw via actions/cache,
# so "what the agent has learned" (memory, sessions, cron run history) carries
# over between the scheduled 15-minute runs.
#
# Drive modes (OPENCLAW_GHA_DRIVE):
#   manual    (default) — disable the periodic scheduler (OPENCLAW_SKIP_CRON=1)
#                          and trigger due jobs explicitly via `cron run --due`.
#                          Deterministic; no duplicate firing.
#   scheduler            — let the in-Gateway scheduler fire due jobs on its own,
#                          keep the Gateway alive for OPENCLAW_GHA_DWELL_SECONDS,
#                          then shut down. Use if `cron run` does not execute in
#                          your build.
#
# Environment:
#   OPENCLAW_BIN              openclaw CLI binary           (default: openclaw)
#   OPENCLAW_GATEWAY_PORT     gateway port                  (default: 18789)
#   OPENCLAW_GHA_DRIVE        manual | scheduler            (default: manual)
#   OPENCLAW_GHA_DWELL_SECONDS scheduler dwell time         (default: 180)
#   OPENCLAW_GHA_JOB_TIMEOUT  per-job wait timeout          (default: 10m)
#   OPENCLAW_GHA_HEALTH_TIMEOUT seconds to await /healthz   (default: 120)
# ---------------------------------------------------------------------------
set -euo pipefail

OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
DRIVE="${OPENCLAW_GHA_DRIVE:-manual}"
DWELL_SECONDS="${OPENCLAW_GHA_DWELL_SECONDS:-180}"
JOB_TIMEOUT="${OPENCLAW_GHA_JOB_TIMEOUT:-10m}"
HEALTH_TIMEOUT="${OPENCLAW_GHA_HEALTH_TIMEOUT:-120}"

STATE_DIR="${HOME}/.openclaw"
JOBS_FILE="${STATE_DIR}/cron/jobs.json"
HEALTH_URL="http://127.0.0.1:${GATEWAY_PORT}/healthz"

log()  { printf '\033[36m[cron]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[cron]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[cron]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[cron]\033[0m %s\n' "$*" >&2; }

GW_PID=""

# Gracefully stop the Gateway so it can flush state, then fall back to SIGKILL.
stop_gateway() {
  if [[ -n "${GW_PID}" ]] && kill -0 "${GW_PID}" 2>/dev/null; then
    log "Stopping Gateway (pid ${GW_PID}) for clean state flush..."
    kill -TERM "${GW_PID}" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "${GW_PID}" 2>/dev/null || { ok "Gateway stopped."; GW_PID=""; return 0; }
      sleep 1
    done
    warn "Gateway did not exit in time — sending SIGKILL."
    kill -KILL "${GW_PID}" 2>/dev/null || true
    GW_PID=""
  fi
}
trap stop_gateway EXIT INT TERM

# OpenClaw refuses to start when secret/state permissions are too open. Cache
# restore does not always preserve strict modes, so tighten them defensively.
harden_permissions() {
  [[ -d "${STATE_DIR}" ]] || return 0
  find "${STATE_DIR}" -name 'auth-*.json'  -exec chmod 600 {} + 2>/dev/null || true
  find "${STATE_DIR}" -name 'sessions.json' -exec chmod 600 {} + 2>/dev/null || true
  find "${STATE_DIR}" -type d               -exec chmod 700 {} + 2>/dev/null || true
}

wait_for_health() {
  log "Waiting for Gateway health at ${HEALTH_URL} (timeout ${HEALTH_TIMEOUT}s)..."
  for _ in $(seq 1 "${HEALTH_TIMEOUT}"); do
    if curl -fsS --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1; then
      ok "Gateway is healthy."
      return 0
    fi
    if [[ -n "${GW_PID}" ]] && ! kill -0 "${GW_PID}" 2>/dev/null; then
      err "Gateway process exited before becoming healthy. Recent log:"
      tail -n 40 "${RUNNER_TEMP:-/tmp}/openclaw-gateway.log" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
  err "Gateway did not become healthy within ${HEALTH_TIMEOUT}s. Recent log:"
  tail -n 40 "${RUNNER_TEMP:-/tmp}/openclaw-gateway.log" 2>/dev/null || true
  return 1
}

start_gateway() {
  local logfile="${RUNNER_TEMP:-/tmp}/openclaw-gateway.log"
  log "Starting Gateway on loopback:${GATEWAY_PORT} (drive=${DRIVE})..."
  # OPENCLAW_NO_RESPAWN keeps this a single foreground-style process we can signal.
  OPENCLAW_NO_RESPAWN=1 \
    "${OPENCLAW_BIN}" gateway --allow-unconfigured --bind loopback --port "${GATEWAY_PORT}" \
    >"${logfile}" 2>&1 &
  GW_PID=$!
  log "Gateway pid: ${GW_PID} (log: ${logfile})"
}

# Drive due jobs explicitly. Each job runs with --due so only jobs whose own
# cron expression is due actually execute. We never abort the whole tick on a
# single job failure; failures are collected and surfaced at the end.
run_due_jobs() {
  if [[ ! -f "${JOBS_FILE}" ]]; then
    warn "No cron jobs file at ${JOBS_FILE} — nothing to run."
    return 0
  fi

  mapfile -t job_ids < <(jq -r '.jobs[]? | select(.enabled == true) | .id' "${JOBS_FILE}")
  if [[ "${#job_ids[@]}" -eq 0 ]]; then
    warn "No enabled cron jobs found."
    return 0
  fi

  log "Found ${#job_ids[@]} enabled job(s). Triggering due jobs..."
  local failures=0
  for id in "${job_ids[@]}"; do
    local name
    name="$(jq -r --arg id "${id}" '.jobs[] | select(.id==$id) | .name' "${JOBS_FILE}")"
    log "→ ${name} (${id})"
    if "${OPENCLAW_BIN}" cron run "${id}" --due --wait \
         --wait-timeout "${JOB_TIMEOUT}" --poll-interval 5s; then
      ok "  done: ${name}"
    else
      rc=$?
      # rc!=0 includes 'not due' / 'skipped' as well as real errors; log and continue.
      warn "  job returned non-zero (rc=${rc}) — likely not-due/skipped, or an error. See run history."
      failures=$((failures + 1))
    fi
  done

  if [[ "${failures}" -gt 0 ]]; then
    warn "${failures} job(s) returned non-zero (not-due/skipped are expected and counted here)."
  fi
  return 0
}

main() {
  command -v "${OPENCLAW_BIN}" >/dev/null 2>&1 || { err "openclaw CLI not found (${OPENCLAW_BIN})."; exit 1; }
  command -v jq >/dev/null 2>&1 || { err "jq is required but not installed."; exit 1; }
  command -v curl >/dev/null 2>&1 || { err "curl is required but not installed."; exit 1; }

  mkdir -p "${STATE_DIR}"
  harden_permissions

  if [[ "${DRIVE}" == "manual" ]]; then
    # Turn off the periodic scheduler so only our explicit --due triggers fire.
    export OPENCLAW_SKIP_CRON=1
  else
    unset OPENCLAW_SKIP_CRON || true
  fi

  start_gateway
  wait_for_health

  if [[ "${DRIVE}" == "scheduler" ]]; then
    log "Scheduler mode: keeping Gateway alive ${DWELL_SECONDS}s for due jobs to fire..."
    sleep "${DWELL_SECONDS}"
  else
    run_due_jobs
  fi

  stop_gateway
  ok "Cron tick complete."
}

main "$@"
