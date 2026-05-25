#!/usr/bin/env python3
"""S1.3 — Auto-add labels script.
Reads the live desirability list and finds labels missing from our scraping config.

Modes:
  AUTO_ADD_ENABLED = False (default): dry-run, prints candidates only.
  AUTO_ADD_ENABLED = True: adds missing labels and logs the change.

Quarantine logic:
  - Labels dropped from desirability are moved to quarantine_labels (with drop date).
  - Restored within 7 days if they reappear; deleted after 7 days.
"""
import json
import os
import sys
from datetime import datetime, timezone, timedelta

AUTO_ADD_ENABLED = False

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
DESIRABILITY_PATH = os.path.expandvars(
    os.environ.get("SN13_STATE_DIR", os.path.expanduser("~/Library/sn13/desirability"))
) + "/total.current.json"
CONFIG_PATH = os.path.join(REPO_ROOT, "scraping/config/scraping_config_cassian.json")
QUARANTINE_PATH = os.path.join(REPO_ROOT, "state/quarantine_labels.json")
WEIGHT_THRESHOLD_PCT = 0.02   # 2% of max weight


def load_desirability():
    """Returns {platform: {label_lower: weight}} from the current desirability file."""
    with open(DESIRABILITY_PATH) as f:
        data = json.load(f)
    result = {"reddit": {}, "x": {}}
    for entry in data:
        params = entry.get("params", {})
        label = params.get("label")
        platform = params.get("platform", "")
        if label and platform in result:
            key = label.lower()
            result[platform][key] = max(result[platform].get(key, 0), entry.get("weight", 1.0))
    return result


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def get_our_labels(cfg):
    """Returns {platform: set_of_lowercase_labels} from the config."""
    our = {"reddit": set(), "x": set()}
    for scraper in cfg["scraper_configs"]:
        sid = scraper["scraper_id"]
        platform = "reddit" if sid.startswith("Reddit") else "x" if sid.startswith("X") else None
        if platform is None:
            continue
        for lsc in scraper["labels_to_scrape"]:
            for lbl in (lsc.get("label_choices") or []):
                our[platform].add(lbl.lower())
    return our


def load_quarantine():
    if not os.path.exists(QUARANTINE_PATH):
        return {}
    with open(QUARANTINE_PATH) as f:
        return json.load(f)


def save_quarantine(q):
    with open(QUARANTINE_PATH, "w") as f:
        json.dump(q, f, indent=2)


def add_label_to_config(cfg, platform, label):
    """Appends label to the last label_choices bucket for the given platform scraper."""
    scraper_id_prefix = "Reddit" if platform == "reddit" else "X"
    for scraper in cfg["scraper_configs"]:
        if scraper["scraper_id"].startswith(scraper_id_prefix):
            target = scraper["labels_to_scrape"][-1]
            if label not in (target.get("label_choices") or []):
                target.setdefault("label_choices", []).append(label)
            return
    print(f"  WARNING: no scraper found for platform={platform}", file=sys.stderr)


def main():
    for path, name in [(DESIRABILITY_PATH, "desirability"), (CONFIG_PATH, "config")]:
        if not os.path.exists(path):
            print(f"ERROR: {name} file not found: {path}", file=sys.stderr)
            sys.exit(1)

    desirability = load_desirability()
    cfg = load_config()
    our_labels = get_our_labels(cfg)
    quarantine = load_quarantine()
    now = datetime.now(timezone.utc)

    all_dd_keys = set()  # track all desirability labels for quarantine check

    candidates = {"reddit": [], "x": []}

    for platform in ("reddit", "x"):
        dd = desirability[platform]
        if not dd:
            continue
        max_w = max(dd.values())
        threshold = max_w * WEIGHT_THRESHOLD_PCT
        all_dd_keys.update(f"{platform}:{lbl}" for lbl in dd)

        for lbl, weight in sorted(dd.items(), key=lambda x: -x[1]):
            if weight < threshold:
                continue
            if lbl not in our_labels[platform]:
                candidates[platform].append((lbl, weight))

    # --- Quarantine logic ---
    # Quarantine tracks labels that WERE in the desirability list but have since dropped off.
    # Labels in our config but never in the desirability list are not quarantined.
    q_updated = False

    # Update existing quarantine entries
    for key, meta in list(quarantine.items()):
        if key in all_dd_keys:
            # Came back to desirability list — restore
            print(f"  [quarantine] Restoring label: {key}")
            del quarantine[key]
            q_updated = True
        else:
            # Still absent — check expiry
            dropped_at = datetime.fromisoformat(meta["dropped_at"])
            if now - dropped_at >= timedelta(days=7):
                print(f"  [quarantine] Deleting expired label: {key} (dropped {meta['dropped_at']})")
                del quarantine[key]
                q_updated = True

    # Quarantine labels that were previously in desirability (i.e., currently in quarantine tracking)
    # and labels newly dropped from desirability that are in our config.
    # We detect "newly dropped" as: in our config + previously was tracked as a desirability label
    # (i.e., exists in state/quarantine_labels.json from a prior run when it was in desirability).
    # For simplicity: any label in all_dd_keys that is also in our config gets tracked.
    # If it later disappears from all_dd_keys, it goes into quarantine on next run.
    # We record the current desirability set so we can detect drops next time.
    prev_dd_path = os.path.join(os.path.dirname(QUARANTINE_PATH), "prev_desirability_keys.json")
    if os.path.exists(prev_dd_path):
        with open(prev_dd_path) as f:
            prev_dd_keys = set(json.load(f))
        newly_dropped = prev_dd_keys - all_dd_keys
        for key in newly_dropped:
            if key not in quarantine:
                platform, _, lbl = key.partition(":")
                quarantine[key] = {"dropped_at": now.isoformat(), "label": lbl, "platform": platform}
                print(f"  [quarantine] Moving to quarantine: {key}")
                q_updated = True

    with open(prev_dd_path, "w") as f:
        json.dump(sorted(all_dd_keys), f)

    if q_updated:
        save_quarantine(quarantine)

    # --- Report / apply ---
    total_candidates = sum(len(v) for v in candidates.values())
    print(f"\nDesirability coverage gap report ({now.strftime('%Y-%m-%d %H:%M UTC')})")
    print(f"AUTO_ADD_ENABLED = {AUTO_ADD_ENABLED}")
    print(f"Weight threshold: >= {WEIGHT_THRESHOLD_PCT*100:.0f}% of max")
    print(f"Missing labels: {total_candidates} total\n")

    for platform in ("reddit", "x"):
        lst = candidates[platform]
        if not lst:
            print(f"[{platform}] No missing labels above threshold.")
            continue
        print(f"[{platform}] {len(lst)} missing labels:")
        for lbl, w in lst:
            print(f"  {lbl}  (weight={w:.4f})")

    if AUTO_ADD_ENABLED and total_candidates > 0:
        print("\nApplying changes to config...")
        for platform in ("reddit", "x"):
            for lbl, _ in candidates[platform]:
                # Add with original casing from desirability
                add_label_to_config(cfg, platform, lbl)
        with open(CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
        ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        print(f"[{ts}] Added {total_candidates} labels to {CONFIG_PATH}")
    elif total_candidates > 0:
        print(f"\n(dry-run) Set AUTO_ADD_ENABLED = True to apply {total_candidates} changes.")


if __name__ == "__main__":
    main()
