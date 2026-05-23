#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"

state="$1"     # FIRING | RECOVERED | INFO
name="$2"      # e.g. liveness.process
msg="$3"

emoji_for() {
  case "$1" in
    FIRING)    echo "🚨" ;;
    RECOVERED) echo "✅" ;;
    *)         echo "ℹ️" ;;
  esac
}

emoji=$(emoji_for "$state")
host=$(hostname -s)
body="${emoji}  **SN13 miner [${host}]** — ${state} \`${name}\`\n${msg}"

# ── Discord (bot token → REST API) ──────────────────────────────────────────
if [[ -n "${DISCORD_BOT_TOKEN:-}" && -n "${DISCORD_ALERT_CHANNEL:-}" ]]; then
  # Filter secrets from message before posting
  safe_msg=$(printf '%s' "$body" | sed \
    -e 's/0x[0-9a-fA-F]\{64\}/[REDACTED_KEY]/g' \
    -e 's/MTQ[A-Za-z0-9._-]\{70,\}/[REDACTED_TOKEN]/g')
  payload=$("$PYTHON" -c "
import json, sys
print(json.dumps({'content': sys.argv[1], 'username': 'SN13-monitor'}))
" "$(printf '%b' "$safe_msg")" 2>/dev/null || true)
  if [[ -n "$payload" ]]; then
    curl -fsS -m 10 \
      -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "https://discord.com/api/v10/channels/${DISCORD_ALERT_CHANNEL}/messages" >/dev/null 2>&1 || true
  fi
fi

# ── ntfy.sh (optional) ──────────────────────────────────────────────────────
if [[ -n "${ALERT_NTFY_TOPIC:-}" ]]; then
  curl -fsS -m 10 -d "$(printf '%b' "$body")" "https://ntfy.sh/${ALERT_NTFY_TOPIC}" >/dev/null 2>&1 || true
fi

# ── local mail (optional) ───────────────────────────────────────────────────
if [[ -n "${ALERT_MAIL_TO:-}" ]] && command -v mail >/dev/null; then
  printf '%b' "$body" | mail -s "SN13 $state: $name" "$ALERT_MAIL_TO" || true
fi

# ── macOS notification (always on darwin) ───────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
  osascript -e "display notification \"${name}: ${msg}\" with title \"SN13 ${state}\"" 2>/dev/null || true
fi

echo "$(date -u +%FT%TZ) ALERT $state $name $msg" >> "$MONITOR_ROOT/state/monitor.log"
