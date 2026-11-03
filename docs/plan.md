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
| c220g5 | Wisconsin | Intel X520-DA2 10G, dual-port (ixgbe) | Both ports available for experiments. Many nodes. |
| c6620 | Utah | Intel E810 25G/100G (ice) | One port of each speed for experiments; a later option. |

The node type is a profile parameter. Both nodes must come from the same
cluster.

## Profile and scripts

- `profile.py`: a geni-lib profile with parameters for node type, OS image,
  number of links, and whether to add the `core` node. CloudLab can create a
  profile from this repository, so changes are a `git push`.
- `scripts/setup-common.sh`: hugepages (1 GB pages if available), IOMMU
  (`intel_iommu=on iommu=pt`, then reboot) or vfio no-IOMMU mode, Docker, and
  tools. It finds the experiment interfaces by their CloudLab IP addresses and
  never touches the control interface. Safe to re-run.
- `scripts/setup-trex.sh`: TRex v3.08 in `/opt/trex`, its TRex config written
  from the real PCI addresses and NUMA node, and the TRex daemon on port 8090.
  Carries over what the GHA repro learned: the intermediate certificate for
  `trex-tgn.cisco.com`, `--no-scapy-server`, and removing TRex's bundled
  `libstdc++`.
- `scripts/setup-upf.sh`: clones the UPF at a given ref, builds its images,
  binds the experiment ports to vfio-pci and writes `upf.jsonc` for DPDK mode.
- `scripts/setup-wire.sh`: DPDK `testpmd` in io-forward mode between the two
  ports, used instead of the UPF in phase 1.
- `testbed`: one entry point, for example
  `testbed run unary|linerate|integration --ref <branch>`. It builds that
  branch, runs the suite, and copies xunit results, TRex and BESS logs and
  NIC xstats into `results/<ref>/<timestamp>/`.
- `testbed compare <ref-a> <ref-b>`: diff linerate throughput, latency and
  QoS results between two runs, for example `main` against a branch.

## Phases

### Phase 1: TRex receive path on real NICs

Use `testpmd` as the wire on the `upf` node. Run the TRex receive repro from
the UPF scratch branch (`ptf/trex-rx-repro.py`) with `c: 1` and `c: 2`, plain
and GTP-U payloads, on X710 and X520.

Done when we know whether TRex v3.08 in software mode receives everything in
both single-queue and multi-queue modes on X710. Record per-queue xstats and
per-thread CPU use for each run.

### Phase 2: PTF unary and linerate against a UPF branch

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
- Do CloudLab's switches pass arbitrary MAC addresses and GTP-U on experiment
  links without changes? TRex ports run in promiscuous mode, and the switches
  should only see unicast to known MACs, but this needs checking.
- Where should this live long term? Start here, then propose a
  `testbed/cloudlab/` directory upstream once it works.
- Whether to run tests from GHA. A self-hosted runner on a long-lived
  experiment is possible, but experiments expire and self-hosted runners on a
  public repository are a security risk. Start with manual runs.

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
