#!/usr/bin/env bash
# monitor/config.sh — all monitor configuration

# ── paths ───────────────────────────────────────────────────────────────────
MINER_ROOT="/Users/terryyuan/company/fish/miners/data-universe"
MONITOR_ROOT="$MINER_ROOT/monitor"
MINER_DB="$MINER_ROOT/SqliteMinerStorage.sqlite"
MINER_LOG="/tmp/sn13_miner_new.log"   # launchd redirects stdout/stderr here
MINER_PID_FILE=""                      # launchd manages PID; not used
HEALTHCHECK_PY="$MINER_ROOT/sn13_healthcheck.py"
PYTHON="$MINER_ROOT/venv/bin/python"

# ── miner identity ──────────────────────────────────────────────────────────
MINER_UID="${MINER_UID:-243}"
MINER_HOTKEY="${MINER_HOTKEY:-5CfD9YLN16GP9XhowBpAdYaFfdg3Gkdh8VPe56qfLUoLe16E}"
AXON_PORT="${AXON_PORT:-8091}"

# ── alert thresholds ────────────────────────────────────────────────────────
LIVENESS_PROCESS_TOLERATE=2       # 2 min of process down before alerting
LIVENESS_LOG_QUIET_MIN=10         # alert if miner log untouched for 10 min
LIVENESS_AXON_TOLERATE=3          # 3 min of axon unreachable

PIPELINE_TOLERATE=2               # 2 consecutive 15-min cycles failing (= 30 min stalled)
S3_STALE_HOURS=3                  # alert if last S3 upload > 3h ago
OD_QUIET_HOURS=4                  # alert if zero OD submissions in last 4h

COMPLIANCE_TOLERATE=3             # 3 consecutive hourly cycles (= ~3h regression)

# ── registration / balance thresholds ───────────────────────────────────────
INCENTIVE_FLOOR_WARN="${INCENTIVE_FLOOR_WARN:-0.0003}"   # below this → deregistration risk
TAO_BALANCE_WARN="${TAO_BALANCE_WARN:-0.10}"             # below this → ~8 re-registrations left
X_SUCCESS_RATE_WARN="${X_SUCCESS_RATE_WARN:-50}"         # alert if X on-demand success rate < this %

# ── alert channels ──────────────────────────────────────────────────────────
# Using Discord bot token (not webhook) to post to living-miner channel
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-MTQ4OTMzNjI5NTMxMzY0MTU4Mw.GokzKi.Lw5vEWxgvC10mbMSwz2mDn5xSitwk_bvnP8I78}"
DISCORD_ALERT_CHANNEL="${DISCORD_ALERT_CHANNEL:-1507239914755063900}"  # #living-miner
ALERT_NTFY_TOPIC="${ALERT_NTFY_TOPIC:-}"
ALERT_MAIL_TO="${ALERT_MAIL_TO:-}"

# ── auto-remediation policy ─────────────────────────────────────────────────
AUTOFIX_RESTART_MINER=1
AUTOFIX_RESTART_FLAREPROX=0       # off by default — usually a real worker problem
AUTOFIX_RUN_PRUNER=1
AUTOFIX_REFRESH_DESIRABILITY=1

AUTOFIX_MAX_PER_HOUR=3            # prevents thrashing

# ── miner launch (launchd-managed: just kill and KeepAlive restarts it) ─────
MINER_LAUNCH_CMD="launchctl stop com.cassian.sn13-miner"

# ── flareprox ───────────────────────────────────────────────────────────────
FLAREPROX_URLS="${FLAREPROX_URLS:-https://flareprox-1779252573-azgdag.terryyuan03.workers.dev}"

export MINER_ROOT MONITOR_ROOT MINER_DB MINER_LOG MINER_PID_FILE HEALTHCHECK_PY PYTHON
export MINER_UID MINER_HOTKEY AXON_PORT
export DISCORD_BOT_TOKEN DISCORD_ALERT_CHANNEL ALERT_NTFY_TOPIC ALERT_MAIL_TO
export AUTOFIX_RESTART_MINER AUTOFIX_RESTART_FLAREPROX AUTOFIX_RUN_PRUNER AUTOFIX_REFRESH_DESIRABILITY AUTOFIX_MAX_PER_HOUR
export MINER_LAUNCH_CMD FLAREPROX_URLS
export INCENTIVE_FLOOR_WARN TAO_BALANCE_WARN X_SUCCESS_RATE_WARN
