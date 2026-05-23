# SN13 Miner Monitor — Operator Runbook

Three-layer monitoring for the SN13 Data Universe miner.

## What each probe does

| Layer | Script | Cadence | Catches |
|---|---|---|---|
| **L1 Liveness** | `bin/liveness.sh` | every 1 min | Process dead, axon port closed, log silent |
| **L2 Pipeline** | `bin/pipeline.sh` | every 15 min | Scrapers stalled, FlareProx errors, disk full |
| **L3 Compliance** | `bin/compliance.sh` | every 1 hour | Drift, freshness decay, desirability mismatch, P2P cap |

Compliance also triggers `bin/hourly_report.sh` — posts a full status summary to **#living-miner** on Discord.

## Alert flow

1. A check fails N consecutive times (tolerance set per layer in `config.sh`)
2. `bin/alert.sh FIRING <name> <msg>` posts to Discord + macOS notification
3. `bin/troubleshoot.sh <name>` runs in background — attempts autofix, then builds a diag bundle
4. Once the check passes again, `bin/alert.sh RECOVERED <name>` clears the alert

Alerts dedupe: while `state/active_alerts/<name>` exists, repeat failures are silent. Removed on recovery.

## How to silence an alert

**Temporarily (suppress this alert key):**
```bash
touch /Users/terryyuan/company/fish/miners/data-universe/monitor/state/active_alerts/<alert_key>
```
This makes the monitor treat it as "already fired" — no new Discord messages until it recovers.

**Emergency: disable all autofix:**
```bash
# Edit config.sh and set:
AUTOFIX_RESTART_MINER=0
AUTOFIX_RUN_PRUNER=0
AUTOFIX_REFRESH_DESIRABILITY=0
```
Or set `AUTOFIX_MAX_PER_HOUR=0` to rate-limit to zero.

## How to disable autofix for one check

Edit `monitor/bin/troubleshoot.sh` and comment out the relevant case arm. Or set the corresponding `AUTOFIX_*` variable to 0 in `config.sh`.

## Diag bundles

Location: `monitor/state/diag_<timestamp>_<alert>.tar.gz`

Contains: last 1000 lines of monitor.log, last 500 lines of miner log, full state directory snapshot, quick healthcheck JSON, process list, disk usage.

Last 20 bundles kept; older ones auto-deleted.

To inspect:
```bash
tar -tzf monitor/state/diag_<ts>_<alert>.tar.gz   # list contents
tar -xzf monitor/state/diag_<ts>_<alert>.tar.gz -C /tmp/diag/
```

## Crontab

Install: `crontab monitor/crontab.example` (or merge manually with `crontab -e`).

Verify cron is running: `launchctl list | grep com.vix.cron`

## Manual commands

```bash
# Run a check now
monitor/bin/liveness.sh
monitor/bin/pipeline.sh
monitor/bin/compliance.sh

# Send a test alert
monitor/bin/alert.sh INFO test "hello from $(hostname)"

# Build a diag bundle without an alert
monitor/bin/diag_bundle.sh manual

# Run troubleshoot for a specific alert
monitor/bin/troubleshoot.sh liveness.process

# Post an hourly report now
monitor/bin/hourly_report.sh

# View recent monitor events
tail -f monitor/state/monitor.log | python3 -m json.tool

# Show active alerts
ls monitor/state/active_alerts/

# Clear a stuck alert manually
rm monitor/state/active_alerts/<alert_key>
```

## Autofix procedures

| Alert | Autofix | What it does |
|---|---|---|
| `liveness.process` | `autofix_restart_miner` | kills miner process; launchd KeepAlive respawns it in 30s |
| `liveness.axon` | `autofix_restart_miner` | same as above |
| `liveness.log_freshness` | `autofix_restart_miner` | same — process wedged |
| `pipeline.recent_x_rate` | `autofix_probe_flareprox` | probes each FlareProx URL, posts HTTP codes to Discord |
| `pipeline.recent_reddit_rate` | `autofix_probe_flareprox` | same |
| `pipeline.disk_space` | `autofix_run_pruner` | runs `scripts/prune_old_entities.py --confirm` |
| `compliance.stale_entity_count` | `autofix_run_pruner` | same |
| `compliance.desirability_targeting` | `autofix_refresh_desirability` | pulls fresh desirability list from chain |
| `compliance.p2p_capped` | none | posts context; requires manual fix |

## What the monitor will NOT do

- Auto-fix credentials (wallet keys, Reddit OAuth, HF tokens) — always pages instead
- Auto-restart faster than `AUTOFIX_MAX_PER_HOUR` (default 3) times per hour
- Write to the miner's SQLite DB (read-only access only)
- Post secrets to Discord (private keys, tokens filtered before posting)
