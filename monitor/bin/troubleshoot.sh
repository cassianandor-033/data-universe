#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"
source "$MONITOR_ROOT/lib/checks.sh"
source "$MONITOR_ROOT/lib/autofix.sh"
source "$MONITOR_ROOT/lib/log.sh"

alert_key="$1"

# 1. Rate-limit autofix attempts
recent_autofixes=$(grep "^AUTOFIX " "$MONITOR_ROOT/state/monitor.log" 2>/dev/null \
  | awk -v cut="$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ 2>/dev/null)" \
    '$1 > cut' | wc -l | tr -d ' ')
if (( recent_autofixes >= AUTOFIX_MAX_PER_HOUR )); then
  "$MONITOR_ROOT/bin/alert.sh" INFO "$alert_key" \
    "autofix rate-limit hit (${recent_autofixes}/${AUTOFIX_MAX_PER_HOUR} per hr) — manual intervention needed"
  "$MONITOR_ROOT/bin/diag_bundle.sh" "$alert_key"
  exit 0
fi

# 2. Decision tree
case "$alert_key" in
  liveness.registered)
    autofix_reregister "$alert_key"
    ;;
  liveness.process)
    (( AUTOFIX_RESTART_MINER )) && autofix_restart_miner "$alert_key"
    ;;
  liveness.axon)
    if pgrep -f "neurons/miner.py" >/dev/null && (( AUTOFIX_RESTART_MINER )); then
      autofix_restart_miner "$alert_key"
    fi
    ;;
  liveness.log_freshness)
    (( AUTOFIX_RESTART_MINER )) && autofix_restart_miner "$alert_key"
    ;;
  pipeline.recent_x_rate | pipeline.recent_reddit_rate)
    autofix_probe_flareprox "$alert_key"
    ;;
  pipeline.flareprox_workers)
    (( AUTOFIX_RESTART_FLAREPROX )) && autofix_redeploy_flareprox "$alert_key"
    ;;
  pipeline.s3_recency)
    autofix_inspect_s3_uploader "$alert_key"
    ;;
  pipeline.disk_space | compliance.stale_entity_count | compliance.freshness_distribution)
    (( AUTOFIX_RUN_PRUNER )) && autofix_run_pruner "$alert_key"
    ;;
  compliance.desirability_targeting | compliance.desirability_freshness)
    (( AUTOFIX_REFRESH_DESIRABILITY )) && autofix_refresh_desirability "$alert_key"
    ;;
  compliance.p2p_capped)
    "$MONITOR_ROOT/bin/alert.sh" INFO "$alert_key" \
      "P2P is capped by S3+OD. Fix S3/HF uploads or build OD submission rate. See compliance checklist."
    ;;
  *)
    "$MONITOR_ROOT/bin/alert.sh" INFO "$alert_key" \
      "no autofix configured for this alert — building diag bundle"
    ;;
esac

# 3. Always build a diag bundle
"$MONITOR_ROOT/bin/diag_bundle.sh" "$alert_key"
