# Phase 2: PTF tests against a UPF branch

Status: running. On the first run against [omec-project/upf#1331], unary
passed 5 of 5 and linerate 5 of 6; the one failure is a testbed artifact. See
[Results](#results).

Phase 2 runs the UPF's PTF unary and linerate suites from the trex node
against a BESS UPF running in DPDK mode on the upf node, built from any UPF
branch.

```text
trex node                                    upf node
┌────────────────────────┐                   ┌─────────────────────────────┐
│ ptf.sh                 │                   │ upf.sh                      │
│  PTF container ── gRPC (control network) ──┼─▶ bess (up4 pipeline)       │
│  TRex daemon :8090     │                   │   bess-pfcp, bess-routectl  │
│  TRex port 0 ──────────┼── access (N3) ────┼── access 198.18.0.1/30      │
│  TRex port 1 ──────────┼── core (N6) ──────┼── core   198.19.0.1/30      │
└────────────────────────┘                   └─────────────────────────────┘
```

## Set up

Use an experiment from this profile with the UPF role set to `upf`, or keep a
phase 1 experiment: `upf.sh start` stops the `testpmd` wire. Both nodes need
their peers' MACs in `/var/lib/upf-testbed/ports.env` (`PORT0_PEER_MAC`,
`PORT1_PEER_MAC`); on a phase 1 experiment, pull and rerun startup:

```bash
cd /local/repository && sudo git pull && sudo ./scripts/startup.sh wire
```

(`trex` on the trex node.)

## Start the UPF

On the upf node, build the images from the branch under test, then start it:

```bash
sudo /local/repository/scripts/upf.sh build --repo https://github.com/andybavier/upf --ref codex/ptf-framework-modernization
sudo /local/repository/scripts/upf.sh start
sudo /local/repository/scripts/upf.sh status
```

The build compiles BESS from source and takes a while; its log is
`/var/log/upf-testbed/upf-build.log`. `start` mirrors the UPF's
`scripts/docker_setup.sh`:

- a `pause` container holds the network namespace, with veths named `access`
  and `core` that carry each DPDK port's MAC and, as their alias, its PCI
  address, which the BESS pipeline uses to find the port;
- the addresses, static neighbors and routes the PTF tests assume: N3
  198.18.0.1/30 with gNB route 11.1.1.128/25, N6 198.19.0.1/30 with the
  default route, and the TRex ports as the neighbors;
- `bess` runs the `up4` pipeline on two NUMA-local CPUs, with `bess-web`,
  `bess-pfcp` and `bess-routectl` alongside;
- `conf/upf.jsonc` from the branch, changed as the PTF README asks: DPDK mode,
  `measure_flow`, and the interface names `access` and `core`.

BESS's gRPC, web and metrics ports are published on the control network, so
a firewall rule only lets the trex node reach them.

## Run the tests

On the trex node:

```bash
sudo /local/repository/scripts/ptf.sh --upf-repo https://github.com/andybavier/upf --upf-ref codex/ptf-framework-modernization unary
sudo /local/repository/scripts/ptf.sh --upf-repo https://github.com/andybavier/upf --upf-ref codex/ptf-framework-modernization linerate
```

Add a test name to run one, e.g. `linerate baseline`. `ptf.sh` checks out the
branch, builds the PTF image when the commit changes, adapts the PTF config to
this testbed (what step 1 of `ptf/README.md` asks for), starts the TRex
daemon, and runs `ptf/run_tests`:

- `ptf/config/trex-cfg-for-ptf.yaml` gets this host's PCI addresses, MACs and
  threads, keeping the branch's DP core count and memory pools, plus the
  [trex-core#1182] SIMD cap;
- `ptf/tests/linerate/common.py` gets the real TRex and UPF MACs;
- `UPF_ADDR` and `TREX_ADDR` point at the upf node and the local TRex
  daemon.

Results go to `/var/lib/upf-testbed/results/phase2/<timestamp>-<suite>/`:
`run.log`, the PTF xunit logs, `localization.diff` (the config changes
above), `host.txt` and the TRex server log.

## Results

First run, 2026-11-03, c220g5 X710s, UPF and PTF image from
`andybavier/upf` `codex/ptf-framework-modernization` at `cb7a03a4b`, TRex
v3.08 server with the SIMD cap:

| Suite | Test | Result |
|---|---|---|
| unary | `check_rules` PdrTest, FarTest, QerAppTest, QerSessionTest, MetricsTest | 5 passed |
| linerate | `baseline.DownlinkPerformanceBaselineTest` | passed |
| linerate | `mbr` DL and UL, conforming and non-conforming | 4 passed |
| linerate | `qos_metrics.PerFlowQosMetricsTest` | failed: sent 1,000,000, received 1,000,006 |

After `qos_metrics` was changed to count its own stream (`8d157619d`, below),
it passed alone and in the full suite. In that full run and three more runs of
`baseline` alone, `baseline` failed 3 of 4 times on its 99.9th percentile
latency check: 2000 µs against a 1000 µs limit. That test didn't change, and it
passed in the first run.

Final run, 2026-11-03, with the UPF images and PTF image both built from the
#1331 branch at `7a94d6fae` (merged with current `main`), each suite on a
freshly started UPF: unary 5/5, linerate 6/6.

## Known issues

- **Switch frames break exact packet counts.** The CloudLab switch sends a
  60-byte multicast frame to each TRex port about every 30 seconds (2 per
  port per minute on idle links). `qos_metrics` compares TRex's total
  `opackets` with total `ipackets` over a window of about 100 seconds, so it
  sees about 6 extra packets and fails. The UPF's kernel side sent nothing
  during a capture, so the frames don't come from the UPF. A testbed with
  direct cables wouldn't see them. Fixed in the test (`8d157619d` on the
  #1331 branch): it now counts its own stream with `STLFlowLatencyStats`, as
  `baseline` and `mbr` do. Plain `STLFlowStats` doesn't work here, because it
  tags the IP header, which the UPF's GTP-U encapsulation replaces; it
  matched only 15 of 1,000,000 packets.
- **`baseline` fails its tail-latency check on a UPF that has already served
  test runs** ([omec-project/upf#1392]). Investigated 2026-11-03:
  - CPU pinning is as upstream intends: `upf.sh` gives the `bess` container
    two NUMA-local CPUs, like `docker_setup.sh`'s `--cpuset-cpus`, and
    `up4.bess` pins the busy-polling worker to the first. Host isolation
    (`isolcpus`, `nohz_full`) isn't part of the documented setup. It isn't
    the cause either: during a run, TRex's RX and DP threads were preempted
    5–20 times and BESS's worker about 3.6 times a second, each for
    microseconds.
  - The slow packets, 0.1–0.2% at 1–3 ms, come at the start of the traffic.
    TRex leaves start-up spikes out of `total_max` (335 µs) but keeps them in
    the histogram, which the test's percentiles use. 99.9% of packets take
    under 50 µs.
  - Sending the same traffic a second time in the same test was clean (23
    packets ≥ 1 ms, 99.9th percentile 60 µs), so it's a cold-flow effect.
  - It gets worse as the UPF serves more runs. After `upf.sh start`, three
    back-to-back runs gave a 99.9th percentile of 60, 300, then 2000 µs
    (125, 120, then 1,178 packets ≥ 1 ms). The first run of the session
    also passed on a fresh UPF.
  - Suspect, not yet shown: per-flow state in BESS's `FlowMeasure` modules,
    whose tables are only flipped and cleared when something reads session
    stats (normally a Prometheus scrape of the PFCP agent). Scraping
    `/metrics` between runs can't be used as a workaround: it flips the
    buffer behind the test, whose own read then fails with "refusing to read
    active buffer".
  - The PTF branch doesn't change the dataplane, so this is UPF behavior,
    not a regression from #1331. To check `baseline` itself, run it on a
    freshly started UPF (`upf.sh start`).
  - On a freshly started UPF, `baseline` passed at the #1331 branch head
    `7a94d6fae` (merged with current `main`).
- The generated TRex config always gets the SIMD cap from `trex-config.py`,
  so these runs don't by themselves check the `ext_dpdk_opt` line in the
  branch's own `trex-cfg-for-ptf.yaml`.

[trex-core#1182]: https://github.com/cisco-system-traffic-generator/trex-core/issues/1182
[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1392]: https://github.com/omec-project/upf/issues/1392
