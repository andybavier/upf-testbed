"""Two hosts with DPDK NICs for testing the OMEC UPF: a TRex traffic generator
and a UPF host, joined by an access (N3) link and a core (N6) link.

Instructions:
The startup scripts log to `/var/log/upf-testbed/startup.log` on each node and
reboot each node once to enable the IOMMU. Wait until both nodes show the
startup service as finished, then follow `docs/phase1.md` in
https://github.com/andybavier/upf-testbed.
"""

# SPDX-License-Identifier: Apache-2.0

import geni.portal as portal
import geni.rspec.pg as pg

pc = portal.Context()

pc.defineParameter(
    "nodeType",
    "Node type",
    portal.ParameterType.NODETYPE,
    "c220g5",
    legalValues=[
        ("c220g5", "c220g5 (Wisconsin, Intel X520 10G)"),
        ("c6420", "c6420 (Clemson, Intel X710 10G)"),
    ],
    longDescription="Both nodes use this type. Each needs two experiment "
    "ports on its DPDK NIC.",
)
pc.defineParameter(
    "osImage",
    "OS image",
    portal.ParameterType.IMAGE,
    "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD",
    longDescription="Ubuntu 22.04 ships Python 3.10, which the TRex v3.06 "
    "daemon still runs on.",
)
pc.defineParameter(
    "upfRole",
    "UPF node role",
    portal.ParameterType.STRING,
    "wire",
    legalValues=[
        ("wire", "testpmd forwards between the two ports (phase 1)"),
        ("none", "set up the host only"),
    ],
)

params = pc.bindParameters()
request = pc.makeRequestRSpec()

# Each link is its own subnet. The startup scripts find the experiment ports by
# these addresses, so they never touch the control network interface.
LINKS = [("access", "10.10.1"), ("core", "10.10.2")]
ROLES = [("trex", "trex", 1), ("upf", params.upfRole, 2)]

interfaces = {name: [] for name, _ in LINKS}
for node_name, role, host in ROLES:
    node = request.RawPC(node_name)
    node.hardware_type = params.nodeType
    node.disk_image = params.osImage
    for link_name, subnet in LINKS:
        iface = node.addInterface("%s-%s" % (node_name, link_name))
        iface.addAddress(pg.IPv4Address("%s.%d" % (subnet, host), "255.255.255.0"))
        interfaces[link_name].append(iface)
    node.addService(
        pg.Execute(
            shell="bash",
            command="sudo /local/repository/scripts/startup.sh %s" % role,
        )
    )

for link_name, _ in LINKS:
    link = request.Link(link_name)
    for iface in interfaces[link_name]:
        link.addInterface(iface)
    link.bandwidth = 10000000  # kbps

pc.printRequestRSpec(request)
