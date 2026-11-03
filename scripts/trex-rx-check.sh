#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# trex-rx-check.sh VERSION [--avx2-rx]
#
# Check whether a TRex release receives on this host's ports: install it in
# /opt/trex-VERSION next to any others, start it in software mode, send 200k
# packets through the wire and print what came back. Uses the release's own
# client in a Python 3.8 container, which runs clients from v2.x up, so the
# PTF image and its TRex client aren't involved. Run on the trex node.

set -euo pipefail
VERSION="${1:?usage: trex-rx-check.sh VERSION [--avx2-rx]}"
export TREX_VERSION="$VERSION" TREX_DIR="/opt/trex-$VERSION"
source "$(dirname "$0")/lib.sh"
require_root
shift

"$TESTBED_DIR/scripts/install-trex.sh"
"$TESTBED_DIR/scripts/trex.sh" stop
logfile="/var/log/upf-testbed/trex-rx-check-$VERSION.log"
"$TESTBED_DIR/scripts/trex.sh" start "$@" --log "$logfile" > /dev/null
grep -E 'queues mode|DDP|workaround' "$logfile" || true

docker run --rm --network host \
	-v "$TREX_DIR:/trex:ro" \
	-v "$TESTBED_DIR/scripts/rx-check.py:/rx-check.py:ro" \
	python:3.8-slim python /rx-check.py /trex |
	sed "s/^/$VERSION${1:+ $1} /" || true

"$TESTBED_DIR/scripts/trex.sh" stop
