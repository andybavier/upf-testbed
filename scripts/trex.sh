#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# trex.sh start [--cores N] [--memory-from FILE] [--log FILE] [--avx2-rx] | stop
#
# Run the TRex server in interactive mode on the experiment ports, the way the
# PTF testbed runs it: software mode, no hardware flow stats.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

start() {
	local cores=1 memory_from="" logfile=/var/log/upf-testbed/trex.log avx2_rx=""
	while (($#)); do
		case "$1" in
		--cores) cores="$2" && shift ;;
		--memory-from) memory_from="$2" && shift ;;
		--log) logfile="$2" && shift ;;
		# Leave out the SIMD cap that works around trex-core#1182.
		--avx2-rx) avx2_rx=--avx2-rx ;;
		*) die "unknown option $1" ;;
		esac
		shift
	done
	pgrep -f _t-rex-64 > /dev/null && die "TRex is already running"

	python3 "$TESTBED_DIR/scripts/trex-config.py" --cores "$cores" \
		${memory_from:+--memory-from "$memory_from"} $avx2_rx --out "$TREX_DIR/trex_cfg.yaml"
	(cd "$TREX_DIR" && setsid nohup ./t-rex-64 -i --software --no-hw-flow-stat \
		--cfg "$TREX_DIR/trex_cfg.yaml" -c "$cores" --iom 0 --no-scapy-server \
		> "$logfile" 2>&1 < /dev/null &)
	for _ in $(seq 120); do
		if ss -ltn | grep -q ':4501 '; then
			log "TRex is up with $cores DP core(s); log in $logfile"
			return 0
		fi
		sleep 1
	done
	tail -n 40 "$logfile"
	die "TRex did not start"
}

stop() {
	pkill -INT -f _t-rex-64 || return 0
	for _ in $(seq 30); do
		pgrep -f _t-rex-64 > /dev/null || return 0
		sleep 1
	done
	pkill -KILL -f _t-rex-64 || true
	sleep 2
}

case "${1:-}" in
start)
	shift
	start "$@"
	;;
stop) stop ;;
*) die "usage: trex.sh start [--cores N] [--memory-from FILE] [--log FILE] [--avx2-rx] | stop" ;;
esac
