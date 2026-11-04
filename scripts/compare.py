#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The Linux Foundation
"""Compare PTF results between two sets of ptf.sh runs.

usage: compare.py [--markdown] A B

A and B are each a ptf.sh run directory, or a directory of them such as
/var/lib/upf-testbed/results/main. With several runs on a side, each value is
the median across them, so repeated runs smooth out run-to-run noise.

For each test the report shows how many runs passed, then the statistics
ptf-metrics.py recorded: packet loss for each TRex flow-stats read, and
latency for each latency read. A test that reads stats more than once (mbr
tries four rates) gets one row per read, numbered in order.

B is flagged as a regression when:
- a test passed in every A run but not in every B run. The reverse is
  marked "fixed" and isn't flagged;
- loss rose by more than 0.1 percentage points;
- a latency figure rose by more than 25% and by more than 10 us.

Exits 1 if anything is flagged, so a script can stop on it.
"""

import argparse
import json
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

LATENCY_FIELDS = [
    ("average", "avg"),
    ("percentile_50", "p50"),
    ("percentile_99", "p99"),
    ("percentile_99_9", "p99.9"),
    ("total_max", "max"),
    ("jitter", "jitter"),
]
LOSS_SLACK = 0.001
LATENCY_RATIO = 1.25
LATENCY_SLACK_US = 10


def find_runs(path):
    path = Path(path)
    if (path / "host.txt").exists():
        return [path]
    runs = sorted(p.parent for p in path.glob("*/host.txt"))
    if not runs:
        sys.exit(f"compare.py: no ptf.sh runs in {path}")
    return runs


def upf_commit(run):
    for line in (run / "host.txt").read_text().splitlines():
        if line.startswith("upf: "):
            return line.split()[-1][:9]
    return "?"


def outcomes(run):
    """Map each test id to True if it passed in this run, False if not."""
    result = {}
    for xml in sorted((run / "ptf-log" / "ptf-logs").glob("TEST-*.xml")):
        for case in ET.parse(xml).getroot().iter("testcase"):
            failed = any(case.find(tag) is not None for tag in ("failure", "error"))
            skipped = case.find("skipped") is not None
            if not skipped:
                result[case.get("classname")] = not failed
    return result


def metrics(run):
    """Map (test, label) to a value, one entry per recorded statistic."""
    path = run / "ptf-log" / "testbed-metrics.jsonl"
    values = {}
    if not path.exists():
        return values
    reads = defaultdict(int)
    for line in path.read_text().splitlines():
        row = json.loads(line)
        test, kind = row["test"], row["kind"]
        reads[test, kind] += 1
        n = reads[test, kind]
        if kind == "flow":
            tx, rx = row["tx_packets"], row["rx_packets"]
            values[test, f"flow {n} loss %"] = 100 * (tx - rx) / tx if tx else 0.0
        elif kind == "latency":
            for field, name in LATENCY_FIELDS:
                values[test, f"latency {n} {name} us"] = float(row[field])
    return values


def collect(runs):
    passes = defaultdict(list)
    values = defaultdict(list)
    for run in runs:
        for test, ok in outcomes(run).items():
            passes[test].append(ok)
        for key, value in metrics(run).items():
            values[key].append(value)
    return passes, {key: statistics.median(v) for key, v in values.items()}


def regressed(label, a, b):
    if "loss" in label:
        return b - a > 100 * LOSS_SLACK
    return b > a * LATENCY_RATIO and b - a > LATENCY_SLACK_US


def fmt(value):
    if value is None:
        return "-"
    if abs(value) >= 100:
        return f"{value:.0f}"
    return f"{value:.3g}"


def main():
    parser = argparse.ArgumentParser(
        description="Compare PTF results between two sets of ptf.sh runs."
    )
    parser.add_argument("a", help="run directory, or a directory of runs")
    parser.add_argument("b", help="run directory, or a directory of runs")
    parser.add_argument(
        "--markdown", action="store_true", help="print a Markdown table"
    )
    args = parser.parse_args()

    sides = []
    for path in (args.a, args.b):
        runs = find_runs(path)
        commits = sorted({upf_commit(r) for r in runs})
        sides.append((runs, commits, collect(runs)))
    (runs_a, commits_a, (pass_a, med_a)), (runs_b, commits_b, (pass_b, med_b)) = sides

    print(f"A: {args.a}: {len(runs_a)} run(s), UPF {', '.join(commits_a)}")
    print(f"B: {args.b}: {len(runs_b)} run(s), UPF {', '.join(commits_b)}")
    print()

    rows = []
    flagged = 0
    for test in sorted(set(pass_a) | set(pass_b)):
        a, b = pass_a.get(test, []), pass_b.get(test, [])
        a_ok, b_ok = bool(a) and all(a), bool(b) and all(b)
        note = ""
        if a_ok and not b_ok:
            note = "REGRESSION"
            flagged += 1
        elif b_ok and not a_ok:
            note = "fixed"
        rows.append(
            (test, "passed", f"{sum(a)}/{len(a)}", f"{sum(b)}/{len(b)}", "", note)
        )
        labels = sorted(
            {label for t, label in set(med_a) | set(med_b) if t == test},
            key=lambda label: (label.split()[0], int(label.split()[1]), label),
        )
        for label in labels:
            va, vb = med_a.get((test, label)), med_b.get((test, label))
            delta = ""
            bad = False
            if va is not None and vb is not None:
                delta = f"{vb - va:+.3g}"
                bad = regressed(label, va, vb)
            flagged += bad
            rows.append(
                ("", label, fmt(va), fmt(vb), delta, "REGRESSION" if bad else "")
            )

    header = ("test", "measure", "A", "B", "B - A", "flag")
    if args.markdown:
        print("| " + " | ".join(header) + " |")
        print("|" + "---|" * len(header))
        for row in rows:
            print(
                "| "
                + " | ".join(f"`{c}`" if i == 0 and c else c for i, c in enumerate(row))
                + " |"
            )
    else:
        widths = [
            max(len(str(r[i])) for r in rows + [header]) for i in range(len(header))
        ]
        for row in [header] + rows:
            print(
                "  ".join(
                    str(c).ljust(w) for c, w in zip(row, widths, strict=True)
                ).rstrip()
            )

    print()
    print(f"{flagged} regression(s) flagged." if flagged else "No regressions flagged.")
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
