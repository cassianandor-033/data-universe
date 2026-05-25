#!/usr/bin/env python3
"""S1.2 — Desirability diff script.
Usage: desirability_diff.py <prev.json> <curr.json>
Prints: added labels (with weights), removed labels, weight changes.
"""
import json
import sys


def load_labels(path):
    """Returns {label_key: weight} from a desirability_total.json file."""
    with open(path) as f:
        data = json.load(f)
    result = {}
    for entry in data:
        params = entry.get("params", {})
        label = params.get("label")
        if label:
            key = f"{params['platform']}:{label.lower()}"
            result[key] = entry.get("weight", 1.0)
    return result


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <prev.json> <curr.json}", file=sys.stderr)
        sys.exit(1)

    prev = load_labels(sys.argv[1])
    curr = load_labels(sys.argv[2])

    added = {k: v for k, v in curr.items() if k not in prev}
    removed = {k: v for k, v in prev.items() if k not in curr}
    changed = {k: (prev[k], curr[k]) for k in curr if k in prev and prev[k] != curr[k]}

    lines = []
    if added:
        lines.append(f"Added ({len(added)}):")
        for k, w in sorted(added.items()):
            lines.append(f"  + {k}  weight={w:.4f}")
    if removed:
        lines.append(f"Removed ({len(removed)}):")
        for k, w in sorted(removed.items()):
            lines.append(f"  - {k}  weight={w:.4f}")
    if changed:
        lines.append(f"Weight changes ({len(changed)}):")
        for k, (old, new) in sorted(changed.items()):
            lines.append(f"  ~ {k}  {old:.4f} -> {new:.4f}")

    if not lines:
        lines.append("No label changes detected.")

    print("\n".join(lines))


if __name__ == "__main__":
    main()
