# upf-testbed

A [CloudLab](https://www.cloudlab.us) profile and scripts for testing the
[OMEC UPF](https://github.com/omec-project/upf) on physical hosts with DPDK
NICs: a TRex traffic generator and a BESS UPF connected by L2 links.

The testbed has two goals:

1. Run the UPF's PTF unary and linerate tests on real hardware. This
   validated [omec-project/upf#1331].
2. Give contributors a repeatable environment for testing larger UPF changes,
   such as the control-plane refactor in [omec-project/upf#1292].

Status: phases 1 and 2 are done.

- Phase 1 found that TRex v3.05 and later stop receiving on Intel i40e NICs;
  capping DPDK's SIMD width works around it
  ([details](docs/phase1.md#findings)).
- Phase 2 runs the PTF suites against a real UPF built from any branch. With
  #1331, merged upstream, unary passes 5/5 and linerate 6/6. `baseline` needs
  a freshly started UPF ([omec-project/upf#1392];
  [docs/phase2.md](docs/phase2.md)).

Phase 3, tests for the #1292 refactor, is under way: runs now record
linerate statistics, and `scripts/compare.py` compares a branch against
`main` ([docs/phase3.md](docs/phase3.md)). The baseline on `main` is next.
See [docs/plan.md](docs/plan.md).

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
| `scripts/ptf-metrics.py` | Appended to the branch's PTF library to record the TRex statistics tests read |
| `scripts/compare.py` | Compares PTF results between two sets of runs, such as `main` and a branch |
| `scripts/manifest.py` | Reads peer MACs and control addresses from the CloudLab manifest |

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
[omec-project/upf#1392]: https://github.com/omec-project/upf/issues/1392
