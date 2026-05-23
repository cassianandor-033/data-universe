#!/usr/bin/env bash
# monitor/lib/checks.sh — individual check functions

check_miner_process() {
  if pgrep -f "neurons/miner.py" >/dev/null; then return 0; fi
  echo "miner process not found (pgrep -f neurons/miner.py)"
  return 1
}

check_axon_port() {
  if nc -z -w 2 127.0.0.1 "$AXON_PORT" 2>/dev/null; then return 0; fi
  echo "axon port $AXON_PORT not accepting connections"
  return 1
}

check_miner_log_fresh() {
  [[ -f "$MINER_LOG" ]] || { echo "miner log not found at $MINER_LOG"; return 1; }
  local mtime age_min
  mtime=$(stat -f %m "$MINER_LOG" 2>/dev/null || stat -c %Y "$MINER_LOG")
  age_min=$(( ( $(date +%s) - mtime ) / 60 ))
  if (( age_min > LIVENESS_LOG_QUIET_MIN )); then
    echo "miner log not written in ${age_min} min (>${LIVENESS_LOG_QUIET_MIN})"
    return 1
  fi
  return 0
}

check_s3_recency() {
  local f="$MINER_ROOT/state/s3_upload_state.json"
  # SN13 data-universe uses HuggingFace, not S3. Soft-pass if file missing.
  [[ -f "$f" ]] || return 0
  local last
  last=$("$PYTHON" -c "import json; d=json.load(open('$f')); print(d.get('last_upload',''))" 2>/dev/null)
  [[ -n "$last" ]] || { echo "no last_upload recorded in $f"; return 1; }
  local last_epoch age_h
  last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last%.*}" +%s 2>/dev/null || date -d "$last" +%s 2>/dev/null)
  age_h=$(( ( $(date +%s) - last_epoch ) / 3600 ))
  if (( age_h >= S3_STALE_HOURS )); then
    echo "last upload was ${age_h}h ago (>=${S3_STALE_HOURS}h) — scoring risk"
    return 1
  fi
  return 0
}

check_disk_space() {
  local pct
  pct=$(df -P "$MINER_ROOT" | awk 'NR==2 {gsub("%",""); print $5}')
  if (( pct >= 90 )); then
    echo "disk at ${pct}% — DB writes will fail soon"
    return 1
  fi
  return 0
}

# Returns 0 if our hotkey is registered on netuid 13, 1 if not.
check_metagraph_registered() {
  local result
  result=$("$PYTHON" - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '/Users/terryyuan/company/fish/miners/data-universe')
import bittensor as bt
try:
    sub = bt.subtensor(network='finney')
    mg = sub.metagraph(netuid=13)
    import os
    hotkey = os.environ.get('MINER_HOTKEY', '5CfD9YLN16GP9XhowBpAdYaFfdg3Gkdh8VPe56qfLUoLe16E')
    if hotkey in [ax.hotkey for ax in mg.axons]:
        print("REGISTERED")
    else:
        print("NOT_REGISTERED")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
)
  local rc=$?
  if (( rc == 2 )); then
    echo "metagraph check failed: $result"
    return 0  # soft-pass on network errors — don't false-alarm
  fi
  if [[ "$result" == "NOT_REGISTERED" ]]; then
    echo "hotkey $MINER_HOTKEY is NOT in metagraph — deregistered"
    return 1
  fi
  return 0
}

# Returns 1 (warning) if incentive is below the floor threshold.
check_incentive_floor() {
  local incentive
  incentive=$("$PYTHON" - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '/Users/terryyuan/company/fish/miners/data-universe')
import bittensor as bt, os
try:
    sub = bt.subtensor(network='finney')
    mg = sub.metagraph(netuid=13)
    hotkey = os.environ.get('MINER_HOTKEY', '5CfD9YLN16GP9XhowBpAdYaFfdg3Gkdh8VPe56qfLUoLe16E')
    uids = [i for i, ax in enumerate(mg.axons) if ax.hotkey == hotkey]
    if not uids:
        print("NOT_REGISTERED")
    else:
        uid = uids[0]
        inc = float(mg.incentive[uid])
        print(f"{inc:.8f}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
)
  local rc=$?
  if (( rc == 2 )) || [[ "$incentive" == NOT_REGISTERED ]]; then
    return 0  # not-registered will be caught by check_metagraph_registered; soft-pass here
  fi
  if [[ "$incentive" == ERROR* ]]; then
    return 0  # network error — soft-pass
  fi
  # Python-style float comparison via awk
  local below
  below=$(awk -v inc="$incentive" -v thresh="${INCENTIVE_FLOOR_WARN}" 'BEGIN{print (inc+0 < thresh+0) ? "1" : "0"}')
  if [[ "$below" == "1" ]]; then
    echo "incentive ${incentive} < floor ${INCENTIVE_FLOOR_WARN} — deregistration risk"
    return 1
  fi
  return 0
}

# Returns 1 (warning) if free TAO balance < TAO_BALANCE_WARN.
check_tao_balance() {
  local balance
  balance=$("$PYTHON" - <<'PYEOF' 2>&1
import sys
sys.path.insert(0, '/Users/terryyuan/company/fish/miners/data-universe')
import bittensor as bt
try:
    wallet = bt.wallet(name='CrustyTY', hotkey='default')
    sub = bt.subtensor(network='finney')
    bal = sub.get_balance(wallet.coldkeypub.ss58_address)
    print(f"{float(bal):.6f}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
)
  local rc=$?
  if (( rc == 2 )) || [[ "$balance" == ERROR* ]]; then
    return 0  # network error — soft-pass
  fi
  local low
  low=$(awk -v bal="$balance" -v thresh="${TAO_BALANCE_WARN}" 'BEGIN{print (bal+0 < thresh+0) ? "1" : "0"}')
  if [[ "$low" == "1" ]]; then
    echo "TAO balance ${balance} < ${TAO_BALANCE_WARN} — low re-registration runway"
    return 1
  fi
  return 0
}
