#!/usr/bin/env python3
"""Append one row of on-chain incentive data to monitor/data/incentive_history.tsv."""
import sys
import os

# Allow imports from the data-universe package root
sys.path.insert(0, '/Users/terryyuan/company/fish/miners/data-universe')

MONITOR_ROOT = os.path.join(os.path.dirname(__file__), '..')
TSV_PATH = os.path.join(MONITOR_ROOT, 'data', 'incentive_history.tsv')
HOTKEY = os.environ.get('MINER_HOTKEY', '5CfD9YLN16GP9XhowBpAdYaFfdg3Gkdh8VPe56qfLUoLe16E')
HEADER = 'timestamp\tincentive\trank\temission\talpha_staked'

import datetime

def main():
    ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    try:
        import bittensor as bt

        sub = bt.subtensor(network='finney')
        mg = sub.metagraph(netuid=13)

        uid = None
        for i, ax in enumerate(mg.axons):
            if ax.hotkey == HOTKEY:
                uid = i
                break
        if uid is None:
            uid_env = os.environ.get('MINER_UID', '')
            if uid_env:
                uid = int(uid_env)

        if uid is None:
            print(f"[log_incentive] hotkey not found in metagraph, skipping", file=sys.stderr)
            return

        incentive = float(mg.incentive[uid])
        emission = float(mg.emission[uid])
        n = len(mg.uids)
        rank_below = int((mg.incentive < incentive).sum())
        rank_pos = n - rank_below  # rank 1 = best; 256 = worst

        # alpha staked
        try:
            w = bt.wallet(name='CrustyTY', hotkey='default')
            stake = sub.get_stake_for_coldkey_and_hotkey(
                coldkey_ss58=w.coldkeypub.ss58_address,
                hotkey_ss58=w.hotkey.ss58_address,
                netuid=13
            )
            alpha = float(stake)
        except Exception:
            alpha = 0.0

        row = f"{ts}\t{incentive:.8f}\t{rank_pos}\t{emission:.8f}\t{alpha:.4f}"

    except Exception as e:
        print(f"[log_incentive] network error, writing placeholder: {e}", file=sys.stderr)
        row = f"{ts}\tERROR\tERROR\tERROR\tERROR"

    # Write to TSV, creating header if file is new
    os.makedirs(os.path.dirname(TSV_PATH), exist_ok=True)
    write_header = not os.path.exists(TSV_PATH) or os.path.getsize(TSV_PATH) == 0
    with open(TSV_PATH, 'a') as f:
        if write_header:
            f.write(HEADER + '\n')
        f.write(row + '\n')

    print(f"[log_incentive] logged: {row}")


if __name__ == '__main__':
    main()
