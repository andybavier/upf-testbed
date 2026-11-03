#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write the UPF config for this testbed from a UPF checkout's conf/upf.jsonc.

Applies what the PTF README asks for (DPDK mode, `measure_flow`, N3 named
`access` and N6 named `core`) and drops the example PFCP peers, since the PTF
tests program BESS directly.
"""

from __future__ import annotations

import argparse
import json


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments outside strings."""
    out, i, in_string = [], 0, False
    while i < len(text):
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                break
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", help="the checkout's conf/upf.jsonc")
    parser.add_argument("out")
    args = parser.parse_args()

    with open(args.src) as f:
        config = json.loads(strip_comments(f.read()))
    config["mode"] = "dpdk"
    config["measure_flow"] = True
    config["access"]["ifname"] = "access"
    config["core"]["ifname"] = "core"
    config["workers"] = 1
    config.setdefault("cpiface", {})["peers"] = []

    with open(args.out, "w") as f:
        json.dump(config, f, indent=4)
        f.write("\n")


if __name__ == "__main__":
    main()
