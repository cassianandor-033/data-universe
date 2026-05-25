#!/usr/bin/env bash
# SN13 Binary Gate Monitor — Q2 credibility hygiene
#
# Checks gates that zero scoring components if crossed:
#   S3 gate 1: duplicate URI ratio > 10%  → S3 score = 0
#   S3 gate 2: scraper success rate < 80% → S3 score = 0
#   Q5.7:      multiple miner processes   → credibility risk
#
# Integrates with the existing monitor infrastructure (config.sh, alert.sh, log.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINER_ROOT="$(dirname "$SCRIPT_DIR")"
source "$MINER_ROOT/monitor/config.sh"
source "$MINER_ROOT/monitor/lib/log.sh"

# ── Thresholds ────────────────────────────────────────────────────────────────
DUP_WARN=0.05   # warn at 5%  (gate fires at 10%)
DUP_GATE=0.10
SCRAPER_GATE=80 # gate fires below 80% (log window: last 1 hour)
SCRAPER_WARN=90 # warn below 90%

TOLERATE=1      # allow 1 consecutive failure before alerting (avoids single-poll spikes)

# ── Q2.1 — Duplicate URI ratio (24h window) ───────────────────────────────────
check_dup_uri_ratio() {
  local ratio
  ratio=$(sqlite3 "$MINER_DB" "
    SELECT ROUND(1.0 - (COUNT(DISTINCT uri) * 1.0 / COUNT(*)), 4)
    FROM DataEntity
    WHERE datetime > datetime('now', '-24 hours');
  " 2>/dev/null || echo "0")
  ratio="${ratio:-0}"

  echo "[binary_gate] dup_uri_ratio(24h)=${ratio} (gate=${DUP_GATE})"
  log_event "binary_gate.dup_uri_ratio" INFO "ratio=${ratio}"

  local at_gate
  at_gate=$(awk -v r="$ratio" -v g="$DUP_GATE" 'BEGIN{print (r+0 >= g+0) ? "1" : "0"}')
  if [[ "$at_gate" == "1" ]]; then
    echo "dup URI ratio ${ratio} >= gate ${DUP_GATE} — S3 score would be zeroed"
    return 1
  fi

  local at_warn
  at_warn=$(awk -v r="$ratio" -v w="$DUP_WARN" 'BEGIN{print (r+0 >= w+0) ? "1" : "0"}')
  if [[ "$at_warn" == "1" ]]; then
    # Warn but don't count as a failure — use a direct alert at INFO level
    "$MINER_ROOT/monitor/bin/alert.sh" INFO "binary_gate.dup_uri_ratio" \
      "dup URI ratio ${ratio} approaching gate (warn=${DUP_WARN}, gate=${DUP_GATE})" || true
  fi
  return 0
}

# ── Q2.2 — Scraper success rate (last 1 hour from miner log) ─────────────────
check_scraper_success_rate() {
  [[ -f "$MINER_LOG" ]] || { echo "miner log not found — cannot measure scraper rate"; return 0; }

  local since_ts
  since_ts=$(date -u -v-1H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -u -d '1 hour ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || echo "")

  if [[ -z "$since_ts" ]]; then
    echo "could not compute since_ts — skipping scraper rate check"
    return 0
  fi

  # Count SUCCESS and ERROR lines for the reddit scraper (the primary high-weight source)
  local successes errors
  successes=$(awk -v since="$since_ts" '
    /reddit_json_scraper\.py/ && /SUCCESS/ {
      if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr($0, RSTART, RLENGTH)
        if (ts >= since) count++
      }
    }
    END { print count+0 }
  ' "$MINER_LOG")

  errors=$(awk -v since="$since_ts" '
    /reddit_json_scraper\.py/ && /ERROR/ {
      if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr($0, RSTART, RLENGTH)
        if (ts >= since) count++
      }
    }
    END { print count+0 }
  ' "$MINER_LOG")

  local total=$(( successes + errors ))
  if (( total < 5 )); then
    echo "[binary_gate] scraper_success_rate: not enough data (total=${total}) — skipping"
    return 0
  fi

  local pct
  pct=$(awk -v s="$successes" -v t="$total" 'BEGIN{printf "%.1f", (s/t)*100}')

  echo "[binary_gate] scraper_success_rate(1h): ${pct}% (${successes}/${total}) (gate<${SCRAPER_GATE}%)"
  log_event "binary_gate.scraper_success_rate" INFO "pct=${pct} success=${successes} total=${total}"

  local below_gate
  below_gate=$(awk -v p="$pct" -v g="$SCRAPER_GATE" 'BEGIN{print (p+0 < g+0) ? "1" : "0"}')
  if [[ "$below_gate" == "1" ]]; then
    echo "scraper success rate ${pct}% < gate ${SCRAPER_GATE}% — S3 score would be zeroed"
    return 1
  fi

  local below_warn
  below_warn=$(awk -v p="$pct" -v w="$SCRAPER_WARN" 'BEGIN{print (p+0 < w+0) ? "1" : "0"}')
  if [[ "$below_warn" == "1" ]]; then
    "$MINER_ROOT/monitor/bin/alert.sh" INFO "binary_gate.scraper_success_rate" \
      "scraper rate ${pct}% approaching gate (warn=${SCRAPER_WARN}%, gate=${SCRAPER_GATE}%)" || true
  fi
  return 0
}

# ── Q5.7 — Multiple miner processes ──────────────────────────────────────────
check_single_miner_process() {
  local count
  count=$(pgrep -fc 'neurons/miner\.py' 2>/dev/null || echo "0")
  echo "[binary_gate] miner_process_count=${count}"
  log_event "binary_gate.miner_process_count" INFO "count=${count}"

  if (( count > 1 )); then
    echo "${count} miner processes detected — duplicate hotkey run destroys credibility"
    return 1
  fi
  return 0
}

# ── Run all checks via the standard run_check wrapper ────────────────────────
run_check binary_gate.dup_uri_ratio       check_dup_uri_ratio          $TOLERATE
run_check binary_gate.scraper_success     check_scraper_success_rate   $TOLERATE
run_check binary_gate.multi_process       check_single_miner_process   0  # zero tolerance

echo "[binary_gate] check complete: $(date -u +%FT%TZ)"
