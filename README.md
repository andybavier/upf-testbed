# upf-testbed

A [CloudLab](https://www.cloudlab.us) profile and scripts for testing the
[OMEC UPF](https://github.com/omec-project/upf) on physical hosts with DPDK
NICs: a TRex traffic generator and a BESS UPF connected by L2 links.

The testbed has two goals:

1. Run the UPF's PTF unary and linerate tests on real hardware, starting with
   the validation that [omec-project/upf#1331] needs.
2. Give contributors a repeatable environment for testing larger UPF changes,
   such as the control-plane refactor in [omec-project/upf#1292].

Status: planning. See [docs/plan.md](docs/plan.md).

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[omec-project/upf#1292]: https://github.com/omec-project/upf/issues/1292
