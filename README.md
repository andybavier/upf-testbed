# upf-testbed

A [CloudLab](https://www.cloudlab.us) profile and scripts for testing the
[OMEC UPF](https://github.com/omec-project/upf) on physical hosts with DPDK
NICs: a TRex traffic generator and a BESS UPF connected by L2 links.

The testbed has two goals:

1. Run the UPF's PTF unary and linerate tests on real hardware, starting with
   the validation that [omec-project/upf#1331] needs.
2. Give contributors a repeatable environment for testing larger UPF changes,
   such as the control-plane refactor in [omec-project/upf#1292].

Status: phase 1 (TRex through a `testpmd` wire) is ready to try. See
[docs/plan.md](docs/plan.md) for the plan and [docs/phase1.md](docs/phase1.md)
to run it.

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

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
