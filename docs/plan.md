# UPF testbed plan

## Goals

- Reproduce, on hardware we control, the TRex receive problem seen on the
  X710 testbed during review of [omec-project/upf#1331]: TRex port 0 stops
  after about 4087 packets and counts the rest as `rx_missed_errors`.
- Run the UPF's PTF unary and linerate tests against any UPF branch, and use
  that to validate #1331.
- Support the refactor proposed in [omec-project/upf#1292], which changes how
  routing, pipeline construction, configuration and session state work at
  runtime. Those changes need tests that run against a real datapath, not only
  unit tests.
- Make the environment easy for someone else to instantiate from a link and
  run with one command.

## What exists in the UPF repo today

| Layer | Where | Runs on |
|---|---|---|
| Go unit tests, BESS build and tests | `.github/workflows/main.yml` | GHA |
| PFCP to BESS rule checks | `test/integration`, `make test-integration` | Any Linux host |
| PTF unary | `ptf/tests/unary` | TRex plus UPF in DPDK mode |
| PTF linerate | `ptf/tests/linerate`, `ptf/jenkins.sh` | TRex plus UPF in DPDK mode |

`ptf/run_tests` runs `ptf_runner.py` in a container. It reads `TREX_ADDR` and
`UPF_ADDR` from `ptf/.env` and pushes `ptf/config/trex-cfg-for-ptf.yaml` to
the TRex server each run. The old ONF Jenkins job ran `make build` and
`./run_tests -t tests/linerate` on a fixed testbed; nothing replaced it.

## Topology

```text
            control network (ssh, PTF -> TRex RPC, PTF -> BESS gRPC)
   ┌──────────────────────────────┬──────────────────────────────┐
┌──┴───────────┐                                          ┌──────┴───────┐
│ trex         │ port 0 ───────── access (N3) ─────────── │ upf          │
│ TRex v3.08   │ port 1 ───────── core (N6)  ──────────── │ BESS UPF     │
│ PTF runner   │                                          │ (or testpmd) │
└──────────────┘                                          └──────────────┘
```

Later, an optional `core` node runs SD-Core with gNBsim for end-to-end PFCP
and gives the UPF real L3 neighbors.

### Hardware

| Node type | Cluster | NIC | Notes |
|---|---|---|---|
| c6420 | Clemson | Intel X710 10G, dual-port (i40e) | Same NIC family as the #1331 testbed. Two sockets. Need to confirm both ports can be used for experiment links. |
| c220g5 | Wisconsin | Intel X710 10G, dual-port (i40e), firmware 8.50 | CloudLab's hardware page says X520, but the nodes we got had X710s with both ports usable for experiments. Many nodes. |
| c6620 | Utah | Intel E810 25G/100G (ice) | One port of each speed for experiments; a later option. |

The node type is a profile parameter. Both nodes must come from the same
cluster.

## Profile and scripts

- `profile.py`: a geni-lib profile with parameters for node type, OS image,
  number of links, and whether to add the `core` node. CloudLab can create a
  profile from this repository, so changes are a `git push`.
Built in phase 1:

- `scripts/startup.sh`: the startup service on every node. Turns on the IOMMU
  (`intel_iommu=on iommu=pt`, then one reboot), sets up 2 MB hugepages, finds
  the experiment ports by their CloudLab addresses (never the control
  interface), records them in `/var/lib/upf-testbed/ports.env`, binds them to
  vfio-pci, warns about leftover DDP profiles, then sets up the node's role.
  Safe to re-run.
- `scripts/install-trex.sh`: a TRex release in `/opt/trex`, with what the GHA
  repro learned: the intermediate certificate for `trex-tgn.cisco.com` and
  removing TRex's bundled `libstdc++`.
- `scripts/trex-config.py` and `scripts/trex.sh`: a TRex config from the real
  PCI addresses and NUMA layout, with the SIMD cap for [trex-core#1182], and
  starting and stopping TRex the way the PTF testbed runs it.
- `scripts/wire.sh`: DPDK `testpmd` in io-forward mode between the two ports,
  used instead of the UPF in phase 1.
- `scripts/phase1.sh` and `scripts/trex-rx-check.sh`: the phase 1 matrix, and
  a receive check for any TRex release with its own client.

Built in phase 2 (see [phase2.md](phase2.md)):

- `scripts/upf.sh`: builds the UPF images from a branch and runs them in DPDK
  mode the way `scripts/docker_setup.sh` does, with the addresses the PTF
  tests expect.
- `scripts/ptf.sh`: adapts the branch's PTF config to this testbed, starts the
  TRex daemon and runs a PTF suite.
- `testbed`: one entry point, for example
  `testbed run unary|linerate|integration --ref <branch>`. It builds that
  branch, runs the suite, and copies xunit results, TRex and BESS logs and
  NIC xstats into `results/<ref>/<timestamp>/`.
- `testbed compare <ref-a> <ref-b>`: diff linerate throughput, latency and
  QoS results between two runs, for example `main` against a branch.

## Phases

### Phase 1: TRex receive path on real NICs (done)

Used `testpmd` as the wire on the `upf` node and ran the TRex receive repro
from the UPF scratch branch (`ptf/trex-rx-repro.py`) with 1 and 2 DP cores,
plain and GTP-U payloads, on c220g5 X710s.

Result: TRex v3.05 and later stop receiving on i40e NICs once each RX ring
fills, because DPDK 24.03 selects an AVX2 receive function that TRex builds
as a stub ([trex-core#1182]). Capping DPDK at 128-bit SIMD fixes it; the cap
is in this testbed's TRex config and in the UPF's PTF config
([omec-project/upf#1331]). Details, the version bisect and known issues are in
[phase1.md](phase1.md).

### Phase 2: PTF unary and linerate against a UPF branch (running)

On #1331: unary 5/5. In linerate, `qos_metrics` failed on CloudLab switch
frames until the test counted its own stream, and `baseline` fails its 99.9th
percentile latency check on most runs. See [phase2.md](phase2.md).


Replace `testpmd` with the BESS UPF in DPDK mode. Run `ptf/run_tests` for the
unary and linerate suites on `main` and on the #1331 branch.

Done when both suites pass (or fail for known reasons) on #1331, with results
we can post on the PR.

### Phase 3: Tests for the #1292 refactor

- Run `test/integration` on the `upf` node.
- Routing and neighbor scenarios for the Go replacement of
  `route_control.py`: next hops that resolve late, route changes and neighbor
  changes while traffic runs.
- Restart and reconciliation: kill `bessd` or the agent mid-traffic, stall a
  BESS batch, then check that installed rules match the sessions.
- Linerate baselines with `testbed compare` to catch performance regressions.

### Phase 4: End to end

Add the `core` node with SD-Core and gNBsim, and run attach and traffic
scenarios through the UPF.

## Open questions

- Can both X710 ports on c6420 carry experiment links?
- CloudLab's switches learn MAC addresses, so a frame addressed to a MAC
  already seen on its own ingress port is dropped. Phase 1's GTP-U repro
  likely hit this. In phase 2 TRex and the UPF have distinct MACs on each
  link, which should avoid it, but check the PTF MAC constants against the
  real ports.
- Where should this live long term? Start here, then propose a
  `testbed/cloudlab/` directory upstream once it works.
- Whether to run tests from GHA. A self-hosted runner on a long-lived
  experiment is possible, but experiments expire and self-hosted runners on a
  public repository are a security risk. Start with manual runs.

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
[trex-core#1182]: https://github.com/cisco-system-traffic-generator/trex-core/issues/1182
