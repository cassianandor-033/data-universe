#!/usr/bin/env bash
# monitor/lib/log.sh — structured logging and run_check wrapper

log_event() {
  local name="$1" status="$2" msg="$3"
  local ts
  ts=$(date -u +%FT%TZ)
  echo "{\"ts\":\"$ts\",\"check\":\"$name\",\"status\":\"$status\",\"msg\":$(printf '%s' "$msg" | "$PYTHON" -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" \
    >> "$MONITOR_ROOT/state/monitor.log"
}

run_check() {
  local name="$1" fn="$2" tolerate="$3"
  local counter_file="$MONITOR_ROOT/state/consecutive_fails/$name"
  mkdir -p "$(dirname "$counter_file")"

  local msg
  if msg=$($fn 2>&1); then
    # Passed — reset counter, clear alert if active.
    rm -f "$counter_file"
    if [[ -f "$MONITOR_ROOT/state/active_alerts/$name" ]]; then
      rm "$MONITOR_ROOT/state/active_alerts/$name"
      "$MONITOR_ROOT/bin/alert.sh" RECOVERED "$name" "back to passing"
    fi
    log_event "$name" PASS ""
    return 0
  fi

  local fails
  fails=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$counter_file"
  log_event "$name" FAIL "$msg (consecutive=$fails)"

  if (( fails > tolerate )); then
    if [[ ! -f "$MONITOR_ROOT/state/active_alerts/$name" ]]; then
      touch "$MONITOR_ROOT/state/active_alerts/$name"
      "$MONITOR_ROOT/bin/alert.sh" FIRING "$name" "$msg"
      "$MONITOR_ROOT/bin/troubleshoot.sh" "$name" &
    fi
  fi
}

# run_check_synthetic — for checks evaluated externally (e.g. from parsed healthcheck JSON)
run_check_synthetic() {
  local name="$1" msg="$2" tolerate="$3"
  local counter_file="$MONITOR_ROOT/state/consecutive_fails/$name"
  mkdir -p "$(dirname "$counter_file")"

  local fails
  fails=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$counter_file"
  log_event "$name" FAIL "$msg (consecutive=$fails)"

  if (( fails > tolerate )) && [[ ! -f "$MONITOR_ROOT/state/active_alerts/$name" ]]; then
    touch "$MONITOR_ROOT/state/active_alerts/$name"
    "$MONITOR_ROOT/bin/alert.sh" FIRING "$name" "$msg"
    "$MONITOR_ROOT/bin/troubleshoot.sh" "$name" &
  fi
}

# recover_synthetic — call when a synthetic check that was failing is now passing
recover_synthetic() {
  local name="$1"
  local counter_file="$MONITOR_ROOT/state/consecutive_fails/$name"
  rm -f "$counter_file"
  if [[ -f "$MONITOR_ROOT/state/active_alerts/$name" ]]; then
    rm "$MONITOR_ROOT/state/active_alerts/$name"
    "$MONITOR_ROOT/bin/alert.sh" RECOVERED "$name" "back to passing"
    log_event "$name" PASS "recovered"
  fi
}
