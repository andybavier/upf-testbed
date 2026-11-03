#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# wire.sh start|stop|status
#
# Forward everything between the UPF node's two ports with DPDK testpmd, so
# TRex sees a wire where the UPF will be: what TRex sends on core arrives back
# on access, and the other way round.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

PIDFILE=/run/upf-testbed-wire.pid
LOGFILE=/var/log/upf-testbed/wire.log

running() {
	[[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2> /dev/null
}

start() {
	if running; then
		log "testpmd is already running"
		return
	fi
	load_ports
	local cpus
	mapfile -t cpus < <(node_cpus "$PORT0_NUMA" | head -n 3)
	((${#cpus[@]} == 3)) || die "not enough cores on NUMA node $PORT0_NUMA"
	# --stats-period keeps testpmd running without a terminal and logs the
	# port counters every 10 seconds.
	setsid nohup dpdk-testpmd -l "$(
		IFS=,
		echo "${cpus[*]}"
	)" -n 4 -a "$PORT0_PCI" -a "$PORT1_PCI" -- \
		--forward-mode=io --nb-cores=2 --auto-start --stats-period=10 \
		> "$LOGFILE" 2>&1 < /dev/null &
	echo $! > "$PIDFILE"
	sleep 5
	running || {
		tail -n 30 "$LOGFILE"
		die "testpmd did not start"
	}
	log "testpmd is forwarding between $PORT0_PCI and $PORT1_PCI on CPUs ${cpus[*]}"
}

stop() {
	running || return 0
	kill -INT "$(cat "$PIDFILE")"
	for _ in $(seq 10); do
		running || break
		sleep 1
	done
	running && kill -KILL "$(cat "$PIDFILE")"
	rm -f "$PIDFILE"
}

case "${1:-}" in
start) start ;;
stop) stop ;;
status)
	if running; then
		echo "running"
		tail -n 20 "$LOGFILE"
	else
		echo "stopped"
	fi
	;;
*) die "usage: wire.sh start|stop|status" ;;
esac
