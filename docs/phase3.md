# Phase 3: Tests for the #1292 refactor

Status: in progress. Runs record linerate statistics, and `compare.py`
compares a branch against `main`. The baseline on upstream `main` hasn't run
yet: it is waiting on c220g5 nodes.

Phase 3 makes the phase 2 setup useful for checking refactor branches, such
as the control-plane changes proposed in [omec-project/upf#1292], against
`main` on real hardware. Most of that work is meant not to change dataplane
behavior, and the PTF linerate tests that would catch a change only run on a
testbed like this one.

## Recording statistics

The linerate tests check loss and latency against fixed limits and print
almost nothing, so a passing run says little about how close it came. To
record the numbers, `ptf.sh` appends
[`scripts/ptf-metrics.py`](../scripts/ptf-metrics.py) to the branch's
`ptf/lib/trex_utils.py`. It wraps `get_flow_stats` and `get_latency_stats`,
which the tests call to read TRex's statistics, and writes each result, with
the test's name, to `ptf-log/testbed-metrics.jsonl` in the run's results.
The tests see the same values as before. The change is in each run's
`localization.diff`.

Runs are filed by the ref they tested:
`/var/lib/upf-testbed/results/<ref>/<timestamp>-<suite>/`, with `/` in the
ref replaced by `_`. `--label` sets another name, for example to keep two
configurations of one branch apart.

## Comparing runs

[`scripts/compare.py`](../scripts/compare.py) takes two run directories, or
two directories of runs:

```bash
python3 /local/repository/scripts/compare.py \
  /var/lib/upf-testbed/results/main /var/lib/upf-testbed/results/<branch>
```

For each test it shows how many runs passed on each side, then the loss of
each flow-stats read and the latency (average, p50, p99, p99.9, max, jitter)
of each latency read. `mbr` reads stats once per rate, so it gets a row per
read. With several runs on a side, each value is the median across them.

It flags B as a regression when:

- a test passed in every A run but not in every B run (the reverse is marked
  "fixed");
- loss rose by more than 0.1 percentage points;
- a latency figure rose by more than 25% and by more than 10 µs.

and exits 1 if anything is flagged. `--markdown` prints the table for a PR
comment. The thresholds are a first guess; the baseline will show how much
`main` varies between runs, and they should be set from that.

## Workflow

On the upf node, build and start the branch:

```bash
sudo /local/repository/scripts/upf.sh build --repo https://github.com/<you>/upf --ref <branch>
sudo /local/repository/scripts/upf.sh start
```

On the trex node:

```bash
sudo /local/repository/scripts/ptf.sh --upf-repo https://github.com/<you>/upf --upf-ref <branch> unary
sudo /local/repository/scripts/ptf.sh --upf-repo https://github.com/<you>/upf --upf-ref <branch> linerate
```

Run `upf.sh start` again before each linerate run: `baseline`'s tail latency
degrades as one UPF instance serves repeated runs ([omec-project/upf#1392]).
Repeat the linerate run at least three times per ref, then compare with the
same number of runs on `main`.

## Next

- Baseline on upstream `main`: unary once, linerate three times, each on a
  freshly started UPF, then `compare.py` of `main` against itself to measure
  run-to-run noise and set the thresholds.
- The rest of phase 3 in [plan.md](plan.md#phase-3-tests-for-the-1292-refactor):
  `test/integration` on the upf node, routing and neighbor scenarios, and
  restart and reconciliation tests.

[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
[omec-project/upf#1392]: https://github.com/omec-project/upf/issues/1392
