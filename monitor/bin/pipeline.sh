#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"
source "$MONITOR_ROOT/lib/log.sh"
source "$MONITOR_ROOT/lib/checks.sh"

# 1. Run healthcheck in JSON mode (quick, no history write)
out=$(cd "$MINER_ROOT" && "$PYTHON" "$HEALTHCHECK_PY" --quick --format=json --no-history 2>&1) || true

if ! echo "$out" | "$PYTHON" -c 'import sys,json;json.loads(sys.stdin.read())' 2>/dev/null; then
  log_event pipeline.healthcheck_runs FAIL "healthcheck did not produce valid JSON"
  "$MONITOR_ROOT/bin/alert.sh" FIRING pipeline.healthcheck_runs "healthcheck broken: ${out:0:300}"
  exit 1
fi

# 2. Iterate FAIL checks — each becomes a separate named alert.
# Write fired keys to a temp file so bash 3.x (macOS) can use them.
fired_keys_file=$(mktemp)
trap "rm -f $fired_keys_file" EXIT

while IFS=$'\t' read -r name detail; do
  alert_key="pipeline.$name"
  echo "$alert_key" >> "$fired_keys_file"
  run_check_synthetic "$alert_key" "$detail" "$PIPELINE_TOLERATE"
done < <(echo "$out" | "$PYTHON" -c '
import json, sys
data = json.load(sys.stdin)
for c in data.get("checks", []):
    if c["status"] == "FAIL":
        print(c["name"] + "\t" + c.get("detail",""))
')

# 3. Recover alert keys that are no longer failing
for alert_file in "$MONITOR_ROOT/state/active_alerts/"pipeline.*; do
  [[ -f "$alert_file" ]] || continue
  key=$(basename "$alert_file")
  if ! grep -qx "$key" "$fired_keys_file" 2>/dev/null; then
    recover_synthetic "$key"
  fi
done

# 4. Special cases not in healthcheck
run_check pipeline.s3_recency         check_s3_recency              "$PIPELINE_TOLERATE"
run_check pipeline.disk_space         check_disk_space              0
run_check pipeline.x_ondemand_rate    check_x_ondemand_success_rate "$PIPELINE_TOLERATE"
