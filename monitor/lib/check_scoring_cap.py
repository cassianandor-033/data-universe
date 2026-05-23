#!/usr/bin/env python3
"""Detect whether the min(P2P, S3+OD) cap is strangling our score."""
import json, os, sys, urllib.request

uid = os.environ.get("MINER_UID")
if not uid:
    sys.exit(0)  # can't check without UID — soft pass

try:
    r = urllib.request.urlopen(
        f"https://sn13-dashboard.api.macrocosmos.ai/api/miners/{uid}",
        timeout=10,
    )
    data = json.loads(r.read())
except Exception:
    sys.exit(0)  # dashboard unreachable — soft pass

p2p = data.get("score_p2p")
s3  = data.get("score_s3")
od  = data.get("score_od")
if None in (p2p, s3, od):
    sys.exit(0)

if p2p >= (s3 + od) - 1e-9:
    print(f"P2P ({p2p:.4f}) >= S3+OD ({s3+od:.4f}) — P2P is being capped")
    sys.exit(1)

sys.exit(0)
