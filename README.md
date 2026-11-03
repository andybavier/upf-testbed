# upf-testbed

A [CloudLab](https://www.cloudlab.us) profile and scripts for testing the
[OMEC UPF](https://github.com/omec-project/upf) on physical hosts with DPDK
NICs: a TRex traffic generator and a BESS UPF connected by L2 links.

The testbed has two goals:

1. Run the UPF's PTF unary and linerate tests on real hardware, starting with
   the validation that [omec-project/upf#1331] needs.
2. Give contributors a repeatable environment for testing larger UPF changes,
   such as the control-plane refactor in [omec-project/upf#1292].

Status: phase 1 is done. It found that TRex v3.05 and later stop receiving on
Intel i40e NICs, and the testbed's TRex config works around it
([details](docs/phase1.md#findings)). Phase 2, the PTF tests against a real
UPF, runs: on PR #1331, unary passes 5/5 and linerate 5/6
([docs/phase2.md](docs/phase2.md)). See
[docs/plan.md](docs/plan.md) for the plan.

## Layout

| Path | Purpose |
|---|---|
| `profile.py` | CloudLab profile: `trex` and `upf` nodes joined by access and core links |
| `scripts/startup.sh` | Startup service on each node: IOMMU, hugepages, vfio-pci, then the node's role |
| `scripts/install-trex.sh` | Installs the TRex server in `/opt/trex` |
| `scripts/trex.sh` | Starts and stops the TRex server on the experiment ports |
| `scripts/trex-config.py` | Writes a TRex config from the host's ports and NUMA layout |
| `scripts/wire.sh` | Runs `testpmd` as a wire on the upf node |
| `scripts/phase1.sh` | Runs the phase 1 receive tests and summarizes them |
| `scripts/trex-rx-check.sh` | Checks whether any TRex release receives on this host, using its own client |
| `scripts/rx-check.py` | The client side of `trex-rx-check.sh` |
| `scripts/upf.sh` | Builds the BESS UPF from a branch and runs it in DPDK mode on the upf node |
| `scripts/upf-config.py` | Writes the UPF config the PTF tests need |
| `scripts/ptf.sh` | Runs the PTF unary or linerate suite from the trex node |
| `scripts/manifest.py` | Reads peer MACs and control addresses from the CloudLab manifest |

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
