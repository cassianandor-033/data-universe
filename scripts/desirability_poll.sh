#!/bin/bash
# S1.1 — Desirability poll script
# Copies the miner's live desirability_total.json to the state dir,
# detects changes, and optionally fires a Discord webhook.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MINER_STATE="$REPO_ROOT/state/desirability_total.json"
STATE_DIR="${SN13_STATE_DIR:-$HOME/Library/sn13/desirability}"
mkdir -p "$STATE_DIR"

if [[ ! -f "$MINER_STATE" ]]; then
    echo "ERROR: miner state not found at $MINER_STATE" >&2
    exit 1
fi

cp "$MINER_STATE" "$STATE_DIR/total.new.json"

if [[ -f "$STATE_DIR/total.current.json" ]] && \
   ! diff -q "$STATE_DIR/total.current.json" "$STATE_DIR/total.new.json" > /dev/null 2>&1; then
    cp "$STATE_DIR/total.current.json" "$STATE_DIR/total.previous.json"
    DIFF_REPORT=$(python3 "$(dirname "$0")/desirability_diff.py" \
        "$STATE_DIR/total.previous.json" "$STATE_DIR/total.new.json")
    echo "Desirability list changed:"
    echo "$DIFF_REPORT"
    if [[ -n "${DISCORD_WEBHOOK_URL:-}" ]]; then
        ESCAPED=$(echo "$DIFF_REPORT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        curl -sS -X POST "$DISCORD_WEBHOOK_URL" -H "Content-Type: application/json" \
          -d "{\"content\":\"SN13 Desirability list changed:\n\`\`\`\n${DIFF_REPORT}\n\`\`\`\"}" > /dev/null
    fi
else
    echo "No change detected."
fi

cp "$STATE_DIR/total.new.json" "$STATE_DIR/total.current.json"
echo "Desirability poll complete: $(date -u)"
