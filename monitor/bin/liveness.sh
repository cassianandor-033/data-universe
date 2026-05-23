#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../config.sh"
source "$MONITOR_ROOT/lib/log.sh"
source "$MONITOR_ROOT/lib/checks.sh"

run_check liveness.process       check_miner_process      "$LIVENESS_PROCESS_TOLERATE"
run_check liveness.axon          check_axon_port           "$LIVENESS_AXON_TOLERATE"
run_check liveness.log_freshness check_miner_log_fresh     0   # immediate, no tolerance

# Registration + economic health (each ~5-10s network call)
run_check liveness.registered    check_metagraph_registered  0  # immediate — triggers auto-rereg
run_check liveness.incentive     check_incentive_floor       1  # 1 miss tolerated (avoid transient noise)
run_check liveness.tao_balance   check_tao_balance           0  # immediate — low funds = actionable
