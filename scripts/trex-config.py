#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write a TRex config for this host's two experiment ports.

Threads come from the NIC's NUMA node, one hyperthread per physical core, so
the layout matches a tuned testbed: master, RX, then `--cores` DP threads.
"""

from __future__ import annotations

import argparse
import subprocess

import yaml

# The UPF's PTF tests address the UPF by these MACs (ptf/tests/linerate/
# common.py), so TRex sends to them by default.
UPF_ACCESS_MAC = "40:a6:b7:20:4f:b8"
UPF_CORE_MAC = "40:a6:b7:20:4f:b9"

SIMD_OPT = "--force-max-simd-bitwidth"
SIMD_CAP = f"{SIMD_OPT}=128"


def read_ports(path: str) -> dict[str, str]:
    ports = {}
    with open(path) as f:
        for line in f:
            key, _, value = line.strip().partition("=")
            if key:
                ports[key] = value.strip('"')
    return ports


def cpus_on_node(node: int) -> list[int]:
    """One CPU per physical core on a NUMA node, skipping CPU 0's core."""
    out = subprocess.run(
        ["lscpu", "-p=CPU,CORE,NODE"], check=True, capture_output=True, text=True
    ).stdout
    seen, cpus = set(), []
    for line in out.splitlines():
        if line.startswith("#"):
            continue
        cpu, core, cpu_node = (int(x) for x in line.split(","))
        if cpu_node != node or core in seen:
            continue
        seen.add(core)
        if cpu != 0:
            cpus.append(cpu)
    return cpus


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ports", default="/var/lib/upf-testbed/ports.env")
    parser.add_argument("--cores", type=int, default=1)
    parser.add_argument(
        "--memory-from",
        help="copy the memory section from this TRex config, e.g. the PTF one",
    )
    parser.add_argument(
        "--dpdk-opts-from",
        help="use the ext_dpdk_opt list from this TRex config, if it has one,"
        " instead of adding the SIMD cap",
    )
    parser.add_argument(
        "--avx2-rx",
        action="store_true",
        help="let DPDK pick its AVX2 receive path (stalls i40e on TRex v3.05+)",
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    ports = read_ports(args.ports)
    node = int(ports["PORT0_NUMA"])
    if node < 0:
        node = 0
    cpus = cpus_on_node(node)
    if len(cpus) < 2 + args.cores:
        raise SystemExit(f"NUMA node {node} has only {len(cpus)} usable cores")

    config = {
        "version": 2,
        "port_limit": 2,
        "interfaces": [ports["PORT0_PCI"], ports["PORT1_PCI"]],
        "port_bandwidth_gb": 10,
        "c": args.cores,
        "port_info": [
            # The UPF node's ports, from the manifest, once startup.sh has
            # recorded them.
            {
                "src_mac": ports["PORT0_MAC"],
                "dest_mac": ports.get("PORT0_PEER_MAC", UPF_ACCESS_MAC),
            },
            {
                "src_mac": ports["PORT1_MAC"],
                "dest_mac": ports.get("PORT1_PEER_MAC", UPF_CORE_MAC),
            },
        ],
        "platform": {
            "master_thread_id": cpus[0],
            "rx_thread_id": cpus[1],
            "dual_if": [{"socket": node, "threads": cpus[2 : 2 + args.cores]}],
        },
    }
    # From v3.05, TRex's DPDK picks the i40e AVX2 receive function on AVX2
    # CPUs, but TRex builds it as a stub that returns no packets, so each
    # receive ring fills once and stalls. Capping SIMD at 128 bits selects the
    # SSE path instead. See cisco-system-traffic-generator/trex-core#1182.
    # The UPF's PTF config carries the cap since omec-project/upf#1331, so
    # keep that config's options when it has them; older configs get the cap.
    dpdk_opts = None
    if args.dpdk_opts_from:
        with open(args.dpdk_opts_from) as f:
            dpdk_opts = yaml.safe_load(f)[0].get("ext_dpdk_opt")
    if dpdk_opts is None:
        dpdk_opts = [SIMD_CAP]
    if args.avx2_rx:
        dpdk_opts = [o for o in dpdk_opts if not o.startswith(SIMD_OPT)]
    if dpdk_opts:
        config["ext_dpdk_opt"] = dpdk_opts
    if args.memory_from:
        with open(args.memory_from) as f:
            config["memory"] = yaml.safe_load(f)[0]["memory"]

    text = yaml.safe_dump([config], sort_keys=False)
    with open(args.out, "w") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
