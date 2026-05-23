#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"

alert_key="${1:-manual}"
ts=$(date -u +%Y%m%d_%H%M%S)
out="$MONITOR_ROOT/state/diag_${ts}_${alert_key//\//_}.tar.gz"

tmp=$(mktemp -d)
trap "rm -rf $tmp" EXIT

# Recent monitor log
tail -1000 "$MONITOR_ROOT/state/monitor.log" > "$tmp/monitor.log" 2>/dev/null || true
# Recent miner log
tail -500 "$MINER_LOG" > "$tmp/miner.log" 2>/dev/null || true
# State files
cp -r "$MINER_ROOT/state" "$tmp/miner_state" 2>/dev/null || true
# Quick healthcheck
( cd "$MINER_ROOT" && "$PYTHON" "$HEALTHCHECK_PY" --format=json --quick --no-history \
  > "$tmp/healthcheck.json" 2>/dev/null ) || true
# System snapshot
ps aux | grep -E 'python.*miner|flareprox' > "$tmp/processes.txt" 2>/dev/null || true
df -h > "$tmp/disk.txt" 2>/dev/null || true
{ uptime; uname -a; } > "$tmp/system.txt" 2>/dev/null || true
netstat -an 2>/dev/null | grep "$AXON_PORT" > "$tmp/axon_listen.txt" || true

tar -czf "$out" -C "$tmp" .
echo "$out" >> "$MONITOR_ROOT/state/monitor.log"
echo "diag bundle: $out"

# Keep last 20 bundles
ls -1t "$MONITOR_ROOT/state/diag_"*.tar.gz 2>/dev/null | tail -n +21 | xargs rm -f || true
