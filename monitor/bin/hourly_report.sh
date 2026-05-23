#!/usr/bin/env bash
# Runs every hour alongside the compliance probe.
# Posts a full miner status summary to #living-miner.
set -euo pipefail
source "$(dirname "$0")/../config.sh"

ts=$(date -u '+%Y-%m-%d %H:%M UTC')

# ── on-chain data ─────────────────────────────────────────────────────────
onchain=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import sys, os
sys.path.insert(0, os.environ['MINER_ROOT'])
try:
    import bittensor as bt
    sub = bt.subtensor(network="finney")
    mg = sub.metagraph(13)
    uid_env = os.environ.get("MINER_UID", "")
    hotkey = os.environ.get("MINER_HOTKEY", "")
    # find our uid by hotkey
    uid = None
    for i, ax in enumerate(mg.axons):
        if ax.hotkey == hotkey:
            uid = i
            break
    if uid is None and uid_env:
        uid = int(uid_env)
    if uid is None:
        print("uid=? incentive=? emission=? rank=?/256")
    else:
        incentive = float(mg.incentive[uid])
        emission = float(mg.emission[uid])
        n = len(mg.uids)
        rank = int((mg.incentive < incentive).sum())
        rank_pos = n - rank
        print(f"uid={uid} incentive={incentive:.6f} emission={emission:.6f} rank={rank_pos}/{n}")
except Exception as e:
    print(f"uid=? incentive=? emission=? rank=? err={e}")
PYEOF
)

# ── process status ────────────────────────────────────────────────────────
if pgrep -f "neurons/miner.py" >/dev/null 2>&1; then
  pid=$(pgrep -f "neurons/miner.py" | head -1)
  process_status="✅ PID $pid"
else
  process_status="🔴 DOWN"
fi

# ── axon ──────────────────────────────────────────────────────────────────
if nc -z -w 2 127.0.0.1 "$AXON_PORT" 2>/dev/null; then
  axon_status="✅ port $AXON_PORT open"
else
  axon_status="🔴 port $AXON_PORT closed"
fi

# ── DB entity count ───────────────────────────────────────────────────────
db_count=$("$PYTHON" -c "
import sqlite3
try:
    conn = sqlite3.connect('$MINER_DB', timeout=5)
    n = conn.execute('SELECT COUNT(*) FROM DataEntity').fetchone()[0]
    print(n)
    conn.close()
except Exception as e:
    print('?')
" 2>/dev/null)

# ── recent scraping rates (last hour) ────────────────────────────────────
rates=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import sqlite3, datetime, os
db = os.environ['MINER_DB']
cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1))\
    .isoformat().replace('T', ' ')
try:
    conn = sqlite3.connect(db, timeout=5)
    x = conn.execute(
        "SELECT COUNT(*) FROM DataEntity WHERE source=2 AND datetime > ?", (cutoff,)
    ).fetchone()[0]
    r = conn.execute(
        "SELECT COUNT(*) FROM DataEntity WHERE source=1 AND datetime > ?", (cutoff,)
    ).fetchone()[0]
    conn.close()
    print(f"x={x}/hr reddit={r}/hr")
except Exception as e:
    print(f"x=? reddit=? err={e}")
PYEOF
)

# ── Gravity job rate (last hour from miner log) ───────────────────────────
gravity=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import re, datetime, os
log_path = os.environ['MINER_LOG']
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
submitted = no_data = errors = 0
try:
    with open(log_path, 'r', errors='replace') as f:
        for line in f:
            m = re.search(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
            if not m:
                continue
            try:
                t = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S').replace(
                    tzinfo=datetime.timezone.utc)
            except Exception:
                continue
            if t < cutoff:
                continue
            if 'Submitted' in line or 'submitted' in line:
                submitted += 1
            elif 'no data' in line.lower() or 'no_data' in line.lower() or '0 results' in line.lower():
                no_data += 1
            elif 'error' in line.lower() or 'Error' in line or 'exception' in line.lower():
                errors += 1
    print(f"submitted={submitted} no_data={no_data} errors={errors}")
except Exception as e:
    print(f"submitted=? no_data=? errors=?")
PYEOF
)

# ── S3 upload status ─────────────────────────────────────────────────────
s3_status=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import re, datetime, os
log_path = os.environ['MINER_LOG']
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=4)
last_success = None
last_fail = None
last_attempt = None
fail_reason = ""
try:
    with open(log_path, 'r', errors='replace') as f:
        for line in f:
            m = re.search(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})', line)
            if not m:
                continue
            try:
                t = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S').replace(
                    tzinfo=datetime.timezone.utc)
            except Exception:
                continue
            if 'Starting S3 partitioned upload' in line:
                last_attempt = t
            elif 'S3 partitioned upload completed successfully' in line:
                last_success = t
            elif 'S3 partitioned upload completed with some failures' in line:
                last_fail = t
            elif 'No jobs found from Gravity' in line and last_attempt:
                fail_reason = "no_jobs_from_gravity"
    if last_success:
        age = int((datetime.datetime.now(datetime.timezone.utc) - last_success).total_seconds() / 60)
        print(f"SUCCESS {age}m ago")
    elif last_fail:
        age = int((datetime.datetime.now(datetime.timezone.utc) - last_fail).total_seconds() / 60)
        detail = f" ({fail_reason})" if fail_reason else ""
        print(f"FAIL {age}m ago{detail}")
    elif last_attempt:
        age = int((datetime.datetime.now(datetime.timezone.utc) - last_attempt).total_seconds() / 60)
        print(f"IN_PROGRESS last attempt {age}m ago")
    else:
        print("no upload attempts in log")
except Exception as e:
    print(f"? ({e})")
PYEOF
)

# ── active alerts ─────────────────────────────────────────────────────────
active_count=$(ls "$MONITOR_ROOT/state/active_alerts/" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$active_count" -eq 0 ]]; then
  alert_line="✅ No active alerts"
else
  alert_names=$(ls "$MONITOR_ROOT/state/active_alerts/" 2>/dev/null | tr '\n' ' ')
  alert_line="🚨 ${active_count} active: ${alert_names}"
fi

# ── wallet alpha ─────────────────────────────────────────────────────────
alpha=$("$PYTHON" - <<'PYEOF' 2>/dev/null
import sys, os
sys.path.insert(0, os.environ['MINER_ROOT'])
try:
    import bittensor as bt
    w = bt.wallet(name="CrustyTY", hotkey="default")
    sub = bt.subtensor(network="finney")
    stake = sub.get_stake_for_coldkey_and_hotkey(
        coldkey_ss58=w.coldkeypub.ss58_address,
        hotkey_ss58=w.hotkey.ss58_address,
        netuid=13
    )
    print(f"{float(stake):.4f}ν")
except Exception as e:
    print(f"?ν ({e})")
PYEOF
)

# ── assemble message ──────────────────────────────────────────────────────
message="📊 **SN13 Hourly Report** — ${ts}

**On-chain:** ${onchain}
**Alpha staked:** ${alpha}

**Process:** ${process_status}
**Axon:** ${axon_status}
**DB entities:** ${db_count}

**Scraping (last 1h):** ${rates}
**Gravity jobs (last 1h):** ${gravity}
**S3 upload:** ${s3_status}

**Alerts:** ${alert_line}"

# Post to Discord
payload=$("$PYTHON" -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$message" 2>/dev/null)
curl -fsS -m 10 \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "https://discord.com/api/v10/channels/${DISCORD_ALERT_CHANNEL}/messages" >/dev/null 2>&1 || \
  echo "$(date -u +%FT%TZ) WARNING: hourly report failed to post to Discord" >> "$MONITOR_ROOT/state/monitor.log"

log_event() {
  echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"check\":\"hourly_report\",\"status\":\"PASS\",\"msg\":\"posted to Discord\"}" \
    >> "$MONITOR_ROOT/state/monitor.log"
}
log_event
