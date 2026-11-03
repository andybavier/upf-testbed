# Phase 2: PTF tests against a UPF branch

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

[trex-core#1182]: https://github.com/cisco-system-traffic-generator/trex-core/issues/1182
