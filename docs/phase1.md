# Phase 1: TRex receive path on real NICs

Status: done. The receive stall is a TRex bug on Intel i40e NICs, and the
testbed now works around it. See [Findings](#findings).

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
2. Instantiate it. Pick the node type. `c220g5` (Wisconsin) worked and had
   X710 NICs, the same family as the #1331 testbed. `c6420` (Clemson) is
   untested. Leave the UPF role at `wire`.
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

- `received` equal to `sent` with `latency samples` equal to `sent`: TRex
  receives everything. This is what a healthy run looks like.
- About 4087 received per receive queue (4087 with 1 core, 8174 with 2) and
  `rx_missed_errors` for the rest: each RX ring filled once and was never
  drained. On i40e NICs with TRex v3.05 or later, that's the AVX2 stub bug
  below. Check that the case's `trex-cfg-<case>.yaml` has the `ext_dpdk_opt`
  SIMD cap.
- `rx_unknown_protocol_packets` equal to the received count is normal on
  these NICs; DPDK's own `testpmd` shows the same.

## Findings

TRex v3.05 moved to DPDK 24.03. On CPUs with AVX2 and AVX-512, DPDK then
selects the i40e AVX2 receive function, which TRex builds as a stub that
returns no packets, so each RX ring fills once and stalls
([trex-core#1182]). It happens in software and hardware mode, with any number
of cores, and with any client. Capping DPDK at 128-bit SIMD selects the
working SSE path:

```yaml
  ext_dpdk_opt: ["--force-max-simd-bitwidth=128"]
```

`trex-config.py` adds this by default, and the same line is now in the UPF's
`ptf/config/trex-cfg-for-ptf.yaml` ([omec-project/upf#1331]). On c220g5 X710s
(firmware 8.50, Xeon Silver 4114), TRex servers in software mode, each with
its own client, received this out of 100,001 packets:

| Server | Without the cap | With the cap |
|---|---|---|
| v2.92, v3.02, v3.04 | all | |
| v3.05, v3.06, v3.08 | 4087, then `rx_missed_errors` | all |

With the cap, `phase1.sh` received every plain packet with full latency
samples, with 1 and 2 DP cores.

Things that turned out not to matter: NIC firmware (8.50 here, 6.01 on the
#1331 testbed), the IOMMU, TRex's DDP profile, the `#508` extra-queue
workaround, software versus hardware mode, and the PTF image's TRex client.

### Checking new TRex releases

To see whether a release still needs the cap, run this on the trex node with
the release in place of `v3.08`:

```bash
sudo /local/repository/scripts/trex-rx-check.sh v3.08 --avx2-rx
```

It installs the release in `/opt/trex-<version>` and sends 200,000 packets
through the wire using that release's own client. If it receives them all
without the cap, the workaround can come out of the PTF config. Without
`--avx2-rx` it checks the release with the cap. `phase1.sh --avx2-rx` does
the same for the full phase 1 matrix.

## Known issues

- The GTP-U rows receive nothing, and nothing is counted as missed either:
  the frames never reach TRex. The likely cause, not yet confirmed:
  `trex-rx-repro.py` addresses them to the PTF constant `TREX_SRC_MAC`, which
  the CloudLab switch has already learned on TRex's own core port, so the
  switch drops them instead of sending them back out that port. This is a flaw in the repro, not in the UPF tests,
  which send GTP-U on the access link.
- With the PTF config's memory section, the first GTP-U case crashed TRex:
  the 128-byte mbuf pool ran out (0 of 1024 free) in `alloc_node_with_vm`.
  GTP-U frames are about 100 bytes, and the PTF config's `mbuf_128: 512` is
  too small for TRex's transmit side. Worth checking for any PTF linerate
  test that sends GTP-U from TRex.
- A previous user can leave TRex's DDP profile on a node's X710, and only a
  power cycle clears it. `startup.sh` lists DDP profiles and warns if one is
  loaded.

[omec-project/upf#1331]: https://github.com/omec-project/upf/pull/1331
[trex-core#1182]: https://github.com/cisco-system-traffic-generator/trex-core/issues/1182
