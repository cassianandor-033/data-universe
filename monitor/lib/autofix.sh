#!/usr/bin/env bash
# monitor/lib/autofix.sh — auto-remediation procedures
# Each autofix must: log AUTOFIX line (rate-limiter reads it), be idempotent, post result alert.

autofix_reregister() {
  local key="$1"
  log_event "autofix.reregister" ATTEMPT ""
  echo "AUTOFIX reregister ATTEMPT $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  local out rc
  out=$("$PYTHON" - 2>&1 <<'PYEOF'
import sys, os
sys.path.insert(0, '/Users/terryyuan/company/fish/miners/data-universe')
import bittensor as bt
wallet = bt.wallet(name='CrustyTY', hotkey='default')
subtensor = bt.subtensor(network='finney')
subtensor.burned_register(wallet=wallet, netuid=13)
print("OK")
PYEOF
)
  rc=$?

  if (( rc == 0 )) && echo "$out" | grep -q "OK"; then
    log_event "autofix.reregister" SUCCESS ""
    echo "AUTOFIX reregister SUCCESS $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" RECOVERED "$key" \
      "auto-reregistration succeeded — hotkey back on netuid 13. Credibility reset; rebuilding."
  else
    log_event "autofix.reregister" FAIL "$out"
    echo "AUTOFIX reregister FAIL $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" FIRING "$key" \
      "auto-reregistration FAILED — manual intervention required. Output: ${out:0:500}"
  fi
}

autofix_restart_miner() {
  local key="$1"
  log_event "autofix.restart_miner" ATTEMPT ""
  echo "AUTOFIX restart_miner ATTEMPT $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  # Graceful kill — launchd KeepAlive will restart within 30s throttle interval
  pkill -f "neurons/miner.py" || true
  sleep 35  # wait for launchd to restart

  if pgrep -f "neurons/miner.py" >/dev/null; then
    log_event "autofix.restart_miner" SUCCESS ""
    echo "AUTOFIX restart_miner SUCCESS $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "auto-restart succeeded (launchd respawned process)"
  else
    log_event "autofix.restart_miner" FAIL "process did not come back up"
    echo "AUTOFIX restart_miner FAIL $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" FIRING "$key" "auto-restart FAILED — launchd did not respawn. Manual intervention required."
  fi
}

autofix_probe_flareprox() {
  local key="$1"
  log_event "autofix.probe_flareprox" ATTEMPT ""
  echo "AUTOFIX probe_flareprox $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  local report=""
  IFS=',' read -ra urls <<< "${FLAREPROX_URLS:-}"
  for u in "${urls[@]}"; do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -m 8 \
      "$u/?url=https://syndication.twitter.com/srv/timeline-profile/screen-name/jack" 2>/dev/null || echo "ERR")
    report+="$u → HTTP $code\n"
  done
  "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "FlareProx probe results:\n$report"
}

autofix_redeploy_flareprox() {
  local key="$1"
  log_event "autofix.redeploy_flareprox" ATTEMPT ""
  echo "AUTOFIX redeploy_flareprox $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  local fp_dir="$MINER_ROOT/../flareprox"
  if [[ ! -f "$fp_dir/flareprox.py" ]]; then
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "flareprox tool not found at $fp_dir — cannot redeploy"
    return 1
  fi

  local new_url
  new_url=$( cd "$fp_dir" && "$PYTHON" flareprox.py create 2>&1 | grep -Eo 'https://[a-z0-9-]+\.workers\.dev' | head -1 )
  if [[ -n "$new_url" ]]; then
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "new FlareProx worker deployed: $new_url — add to FLAREPROX_URLS and restart miner"
    log_event "autofix.redeploy_flareprox" SUCCESS "$new_url"
  else
    "$MONITOR_ROOT/bin/alert.sh" FIRING "$key" "FlareProx deploy failed — check Cloudflare account"
    log_event "autofix.redeploy_flareprox" FAIL ""
  fi
}

autofix_run_pruner() {
  local key="$1"
  log_event "autofix.run_pruner" ATTEMPT ""
  echo "AUTOFIX run_pruner $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  local pruner="$MINER_ROOT/scripts/prune_old_entities.py"
  if [[ ! -f "$pruner" ]]; then
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "pruner not found at $pruner"
    return 1
  fi
  if ( cd "$MINER_ROOT" && "$PYTHON" "$pruner" --confirm ) 2>&1; then
    log_event "autofix.run_pruner" SUCCESS ""
    echo "AUTOFIX run_pruner SUCCESS $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "pruner ran successfully — stale entities removed"
  else
    log_event "autofix.run_pruner" FAIL ""
    echo "AUTOFIX run_pruner FAIL $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
  fi
}

autofix_refresh_desirability() {
  local key="$1"
  log_event "autofix.refresh_desirability" ATTEMPT ""
  echo "AUTOFIX refresh_desirability $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"

  if ( cd "$MINER_ROOT" && timeout 180 "$PYTHON" -m dynamic_desirability.desirability_retrieval ) 2>&1; then
    log_event "autofix.refresh_desirability" SUCCESS ""
    echo "AUTOFIX refresh_desirability SUCCESS $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
    "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "desirability list refreshed from chain"
  else
    log_event "autofix.refresh_desirability" FAIL ""
    echo "AUTOFIX refresh_desirability FAIL $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
  fi
}

autofix_inspect_s3_uploader() {
  local key="$1"
  log_event "autofix.inspect_s3_uploader" ATTEMPT ""
  echo "AUTOFIX inspect_s3_uploader $(date -u +%FT%TZ)" >> "$MONITOR_ROOT/state/monitor.log"
  local recent_log
  recent_log=$(grep -iE 'upload|hf_hub|huggingface' "$MINER_LOG" 2>/dev/null | tail -30)
  "$MONITOR_ROOT/bin/alert.sh" INFO "$key" "HF upload stalled — recent upload log lines included in diag bundle"
}
