# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash disable=SC2034
# Shared settings and helpers for the testbed scripts. Source, don't run.

TESTBED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR=/var/lib/upf-testbed
PORTS_ENV="$STATE_DIR/ports.env"
TREX_DIR=/opt/trex
TREX_VERSION="${TREX_VERSION:-v3.08}"

# Experiment port addresses from profile.py, in TRex port order: port 0 is
# access (N3), port 1 is core (N6), matching the UPF's PTF tests.
PORT_SUBNETS=(10.10.1 10.10.2)

log() {
	echo "[$(date -u +%H:%M:%S)] $*" >&2
}

die() {
	log "ERROR: $*"
	exit 1
}

# Print the interface that holds an address in the given /24, if any.
iface_in_subnet() {
	ip -o -4 addr show | awk -v prefix="$1." 'index($4, prefix) == 1 { print $2; exit }'
}

# Load PORT<n>_{IFACE,PCI,MAC,NUMA,DRIVER,FIRMWARE} written by record_ports.
load_ports() {
	[[ -f "$PORTS_ENV" ]] || die "$PORTS_ENV is missing; has startup.sh run?"
	# shellcheck source=/dev/null
	source "$PORTS_ENV"
}

port_pcis() {
	load_ports
	echo "$PORT0_PCI $PORT1_PCI"
}

# Ubuntu's dpdk package has installed dpdk-devbind under both names.
devbind() {
	if command -v dpdk-devbind.py > /dev/null; then
		dpdk-devbind.py "$@"
	else
		dpdk-devbind "$@"
	fi
}

# Print one CPU per physical core on a NUMA node, skipping CPU 0's core.
node_cpus() {
	local node="$1"
	((node < 0)) && node=0
	lscpu -p=CPU,CORE,NODE |
		awk -F, -v node="$node" '!/^#/ && $3 == node && !seen[$2]++ && $1 != 0 { print $1 }'
}

require_root() {
	((EUID == 0)) || die "run this with sudo"
}
