# Phase 1: TRex receive path on real NICs

Phase 1 checks whether TRex, run the way the PTF testbed runs it (`-i
--software --no-hw-flow-stat`), receives everything that comes back to it on
a real Intel NIC. On the X710 testbed in [omec-project/upf#1331], TRex port 0
stopped after about 4087 packets and counted the rest as `rx_missed_errors`.
That log showed TRex in multi-queue mode with two DP cores.

The UPF node runs DPDK `testpmd` as a wire between its two ports, so anything
TRex sends on port 1 (core) comes back on port 0 (access).

## Instantiate

1. In CloudLab, create a profile from this repository (Experiments → Create
   Experiment Profile → Git Repo, `https://github.com/andybavier/upf-testbed`).
2. Instantiate it. Pick the node type: `c6420` (Clemson, X710) to match the
   #1331 testbed, or `c220g5` (Wisconsin, X520). Leave the UPF role at `wire`.
3. Wait for both nodes' startup services to finish. Each node reboots once to
   turn on the IOMMU. Progress is in `/var/log/upf-testbed/startup.log`.

If CloudLab can't map the experiment, the node type probably doesn't offer
two experiment ports on the DPDK NIC. Try the other node type.

## Check the nodes

On the upf node:

```bash
sudo /local/repository/scripts/wire.sh status
```

It should say `running` and show testpmd's port counters.

On the trex node:

```bash
cat /var/lib/upf-testbed/ports.env
```

It lists both experiment ports with their PCI addresses, NUMA node, driver
and firmware. Both should now be bound to `vfio-pci`.

## Run

On the trex node:

```bash
sudo /local/repository/scripts/phase1.sh
```

By default this builds the PTF image from `andybavier/upf` branch
`scratch/trex-fe-repro`, then tries 1 and 2 DP cores, the PTF config's memory
pools and TRex's defaults, and plain and GTP-U payloads. Each combination
starts a fresh TRex server and sends 10,000 pps for 10 seconds, twice.
`phase1.sh --help` lists the options.

Results go to `/var/lib/upf-testbed/results/phase1/<timestamp>/`:

| File | Contents |
|---|---|
| `summary.md` | Sent, received and receive xstats for every run |
| `host.txt` | UPF commit, TRex version, kernel, ports, NIC binding, CPUs |
| `trex-<case>.log` | TRex server output, including the DPDK mode it chose |
| `trex-cfg-<case>.yaml` | The TRex config for that case |
| `threads-<case>.txt` | Per-thread CPU use for TRex partway through the first run |

## Reading the results

- `received` equal to `sent` in every row: TRex receives fine on this NIC in
  both single-queue (`ONE_QUE`, 1 core) and multi-queue (`MULTI_QUE`,
  2 cores) modes. The #1331 testbed's problem is then specific to that host,
  for example its CPU isolation or NIC firmware.
- About 4087 received with `rx_missed_errors` for the rest: the problem
  reproduces. The per-queue xstats (`rx_q0_packets`, `rx_q1_packets`) show
  which queue filled, and `threads-<case>.txt` shows whether the DP thread
  that owns it was running.

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
