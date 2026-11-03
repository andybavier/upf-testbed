#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Send plain UDP from TRex port 1 and count what port 0 receives, using the
client bundled with the TRex release in TREX_DIR (the first argument)."""

import json
import sys
import time

sys.path.insert(0, sys.argv[1] + "/automation/trex_control_plane/interactive")

from scapy.layers.inet import IP, UDP  # noqa: E402
from scapy.layers.l2 import Ether  # noqa: E402
from trex.stl.api import STLClient, STLPktBuilder, STLStream, STLTXCont  # noqa: E402

PPS = 10000
DURATION = 10

client = STLClient(server="127.0.0.1")
client.connect()
try:
    client.acquire(force=True)
    for run in (1, 2):
        client.reset()
        client.clear_stats()
        client.set_port_attr(client.get_all_ports(), promiscuous=True)
        pkt = (
            Ether(dst="40:a6:b7:20:4f:b9", src="40:a6:b7:20:c8:25")
            / IP(src="6.6.6.6", dst="16.0.0.1")
            / UDP(sport=10002, dport=10001)
            / ("x" * 18)
        )
        stream = STLStream(packet=STLPktBuilder(pkt=pkt), mode=STLTXCont(pps=PPS))
        client.add_streams(stream, ports=[1])
        client.start(ports=[1], duration=DURATION)
        client.wait_on_traffic(ports=[1])
        time.sleep(2)
        stats = client.get_stats()
        xstats = client.get_xstats(0)
        print(
            json.dumps(
                {
                    "run": run,
                    "sent": stats[1]["opackets"],
                    "received": stats[0]["ipackets"],
                    "rx_missed_errors": xstats.get("rx_missed_errors", 0),
                }
            ),
            flush=True,
        )
finally:
    client.reset()
    client.release()
    client.disconnect()
