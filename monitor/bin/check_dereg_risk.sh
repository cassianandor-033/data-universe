#!/usr/bin/env bash
# check_dereg_risk.sh — Post CRITICAL alert if rank > 230 AND incentive has been declining
# for 2+ consecutive hours. Reads from monitor/data/incentive_history.tsv.
# Designed to be called from the hourly monitor.
set -euo pipefail
source "$(dirname "$0")/../config.sh"

INCENTIVE_TSV="$MONITOR_ROOT/data/incentive_history.tsv"

result=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import sys, os, datetime

tsv = os.path.join(os.environ['MONITOR_ROOT'], 'data', 'incentive_history.tsv')

try:
    with open(tsv) as f:
        rows = [l.strip().split('\t') for l in f if l.strip() and not l.startswith('timestamp')]
except FileNotFoundError:
    print("NO_DATA")
    sys.exit(0)

def parse_row(r):
    try:
        ts = datetime.datetime.strptime(r[0], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        inc = float(r[1])
        rank = int(r[2])
        return ts, inc, rank
    except Exception:
        return None

parsed = [p for p in (parse_row(r) for r in rows) if p]
if len(parsed) < 3:
    print("INSUFFICIENT_DATA")
    sys.exit(0)

# Use only rows from the last 24h
now = datetime.datetime.now(datetime.timezone.utc)
recent = [p for p in parsed if (now - p[0]).total_seconds() < 86400]
if len(recent) < 3:
    print("INSUFFICIENT_DATA")
    sys.exit(0)

latest = recent[-1]
cur_rank = latest[2]
cur_inc = latest[1]

# Determine consecutive declining hours ending at latest reading
# Walk backwards: each step must be within ~90 min of the previous
decline_count = 0
for i in range(len(recent) - 1, 0, -1):
    cur = recent[i]
    prev = recent[i - 1]
    gap = (cur[0] - prev[0]).total_seconds()
    if gap > 5400:  # more than 90 min between readings — stop
        break
    if cur[1] < prev[1]:
        decline_count += 1
    else:
        break  # streak broken

# Alert condition: rank > 230 AND 2+ consecutive hours declining
RANK_THRESHOLD = 230
if cur_rank > RANK_THRESHOLD and decline_count >= 2:
    # Collect last few readings for the alert message
    tail = recent[-min(5, len(recent)):]
    readings = ', '.join(f"{p[1]:.6f}" for p in tail)
    print(f"ALERT rank={cur_rank} declining_hours={decline_count} readings=[{readings}]")
else:
    print(f"OK rank={cur_rank} decline_streak={decline_count}")
PYEOF
)

if [[ "$result" == ALERT* ]]; then
    # Parse fields
    rank=$(echo "$result" | grep -oP 'rank=\K[0-9]+')
    hours=$(echo "$result" | grep -oP 'declining_hours=\K[0-9]+')
    readings=$(echo "$result" | grep -oP 'readings=\[\K[^\]]+')

    alert_msg="🚨 DEREGISTRATION RISK: rank ${rank}/256, incentive declining for ${hours}h straight. Last readings: ${readings}. Re-register NOW or boost performance."

    payload=$("$PYTHON" -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$alert_msg" 2>/dev/null)
    curl -fsS -m 10 \
      -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "https://discord.com/api/v10/channels/${DISCORD_ALERT_CHANNEL}/messages" >/dev/null 2>&1 || \
      echo "$(date -u +%FT%TZ) WARNING: dereg risk alert failed to post to Discord" >> "$MONITOR_ROOT/state/monitor.log"

    echo "$(date -u +%FT%TZ) CRITICAL: $result" >> "$MONITOR_ROOT/state/monitor.log"
    echo "CRITICAL: $result"
    exit 1
else
    echo "$(date -u +%FT%TZ) INFO: dereg_risk check: $result" >> "$MONITOR_ROOT/state/monitor.log"
    echo "OK: $result"
    exit 0
fi
