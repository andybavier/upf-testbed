#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read facts about the experiment from CloudLab's manifest (`geni-get
manifest`), so each node can configure itself against the other.

  manifest.py peers NODE   PORT<n>_PEER_MAC lines: the MAC at the other end of
                           each of NODE's links, in TRex port order
  manifest.py ip NODE      NODE's control network address
"""

from __future__ import annotations

import subprocess
import sys
import xml.etree.ElementTree as ET

# TRex port order, matching PORT_SUBNETS in lib.sh: port 0 is access (N3),
# port 1 is core (N6).
LINKS = ["access", "core"]


def tag(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def manifest() -> ET.Element:
    out = subprocess.run(
        ["geni-get", "manifest"], check=True, capture_output=True, text=True
    ).stdout
    return ET.fromstring(out)


def mac(raw: str) -> str:
    raw = raw.replace(":", "").lower()
    return ":".join(raw[i : i + 2] for i in range(0, 12, 2))


def peers(root: ET.Element, node: str) -> None:
    macs = {
        e.get("client_id"): mac(e.get("mac_address"))
        for e in root.iter()
        if tag(e) == "interface" and e.get("mac_address")
    }
    links = {
        e.get("client_id"): [
            ref.get("client_id") for ref in e if tag(ref) == "interface_ref"
        ]
        for e in root.iter()
        if tag(e) == "link"
    }
    for i, link in enumerate(LINKS):
        others = [c for c in links[link] if not c.startswith(node + ":")]
        if len(others) != 1:
            sys.exit(f"link {link} does not join {node} to exactly one peer")
        print(f"PORT{i}_PEER_MAC={macs[others[0]]}")


def control_ip(root: ET.Element, node: str) -> None:
    for e in root.iter():
        if tag(e) == "node" and e.get("client_id") == node:
            for child in e.iter():
                if tag(child) == "host" and child.get("ipv4"):
                    print(child.get("ipv4"))
                    return
    sys.exit(f"no control address for {node} in the manifest")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("peers", "ip"):
        sys.exit(__doc__)
    root = manifest()
    if sys.argv[1] == "peers":
        peers(root, sys.argv[2])
    else:
        control_ip(root, sys.argv[2])


if __name__ == "__main__":
    main()
