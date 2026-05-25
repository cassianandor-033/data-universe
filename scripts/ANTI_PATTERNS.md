# SN13 Credibility Anti-Patterns (Q5)

Patterns that destroy credibility (`credibility^2.5` scoring) or zero scoring components.

| # | Pattern | Effect | Gate |
|---|---------|--------|------|
| Q5.1 | Duplicate URIs > 10% of 24h entities | S3 score = 0 | Hard |
| Q5.2 | Scraper success rate < 80% (1h window) | S3 score = 0 | Hard |
| Q5.3 | OD job match rate < 95% | OD score penalized | Hard |
| Q5.4 | Stale data (entities > 30d old) | Freshness penalty | Soft |
| Q5.5 | Desirability list > 2h old | Targeting drift | Soft |
| Q5.6 | Uploading to wrong label buckets | Wasted bandwidth, low reward | Soft |
| Q5.7 | Multiple miner processes on same hotkey | Credibility zeroed | Hard |

**Monitored by:** `scripts/binary_gate_monitor.sh` (hourly via launchd `com.cassian.sn13-binary-gate-monitor`)
