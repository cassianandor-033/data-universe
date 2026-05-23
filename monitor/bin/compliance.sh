#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"
source "$MONITOR_ROOT/lib/log.sh"

# 1. Full healthcheck (writes to history)
out=$(cd "$MINER_ROOT" && "$PYTHON" "$HEALTHCHECK_PY" --format=json 2>&1) || true

fired_keys_file=$(mktemp)
trap "rm -f $fired_keys_file" EXIT

# 2. Surface FAILs and WARNs from full run
while IFS=$'\t' read -r status name detail; do
  alert_key="compliance.$name"
  echo "$alert_key" >> "$fired_keys_file"
  run_check_synthetic "$alert_key" "[$status] $detail" "$COMPLIANCE_TOLERATE"
done < <(echo "$out" | "$PYTHON" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d.get("checks", []):
        if c["status"] in ("FAIL", "WARN"):
            print(c["status"] + "\t" + c["name"] + "\t" + c.get("detail",""))
except Exception as e:
    sys.stderr.write(str(e))
' 2>/dev/null)

# 3. Recover keys no longer failing
for alert_file in "$MONITOR_ROOT/state/active_alerts/"compliance.*; do
  [[ -f "$alert_file" ]] || continue
  key=$(basename "$alert_file")
  if ! grep -qx "$key" "$fired_keys_file" 2>/dev/null; then
    recover_synthetic "$key"
  fi
done

# 4. P2P scoring cap check
"$PYTHON" "$MONITOR_ROOT/lib/check_scoring_cap.py" 2>/dev/null || \
  run_check_synthetic "compliance.p2p_capped" "P2P contribution is being capped by min(P2P, S3+OD)" 0

# 5. Post hourly status report to Discord
"$MONITOR_ROOT/bin/hourly_report.sh"
