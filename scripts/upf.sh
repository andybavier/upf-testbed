#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# upf.sh build [--repo URL] [--ref REF] | start | stop | status
#
# Build the BESS UPF from a UPF branch and run it in DPDK mode on the upf
# node's experiment ports, the way the UPF's scripts/docker_setup.sh does, with
# the addresses the PTF tests expect.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

UPF_REPO=https://github.com/omec-project/upf
UPF_REF=main
SRC="$STATE_DIR/src/upf"
CONF="$STATE_DIR/upf-conf"
LOGDIR=/var/log/upf-testbed
BESSD_PORT=10514
GUI_PORT=8000
METRICS_PORT=8080
CONTAINERS=(bess-routectl bess-pfcp bess-web bess pause)

# From scripts/docker_setup.sh; the PTF tests assume them (N3_IP, GNB_IP and a
# route to PDN_IP in ptf/tests/linerate/common.py). Index 0 is access (N3),
# 1 is core (N6), matching the ports in ports.env.
IFACES=(access core)
IPADDRS=(198.18.0.1/30 198.19.0.1/30)
NHIPADDRS=(198.18.0.2 198.19.0.2)
ROUTES=("11.1.1.128/25" "0.0.0.0/0")

image_tag() {
	cat "$SRC/VERSION"
}

build() {
	while (($#)); do
		case "$1" in
		--repo) UPF_REPO="$2" && shift ;;
		--ref) UPF_REF="$2" && shift ;;
		*) die "unknown option $1" ;;
		esac
		shift
	done
	if [[ ! -d "$SRC/.git" ]]; then
		git clone -q "$UPF_REPO" "$SRC"
	fi
	git -C "$SRC" fetch -q "$UPF_REPO" "$UPF_REF"
	git -C "$SRC" checkout -q --detach FETCH_HEAD
	log "Building upf-bess and upf-pfcp from $UPF_REPO $UPF_REF ($(git -C "$SRC" rev-parse --short HEAD)); log in $LOGDIR/upf-build.log"
	make -C "$SRC" docker-build > "$LOGDIR/upf-build.log" 2>&1 ||
		die "build failed; see $LOGDIR/upf-build.log"
	log "Built upf-bess:$(image_tag) and upf-pfcp:$(image_tag)"
}

stop() {
	docker rm -f "${CONTAINERS[@]}" > /dev/null 2>&1 || true
	rm -f /var/run/netns/pause
	# Remove this script's firewall rules.
	while iptables -D DOCKER-USER -m comment --comment upf-testbed -j DROP 2> /dev/null; do :; done
}

# Docker publishes BESS's gRPC, web and metrics ports on the public control
# network; only let the trex node reach them.
firewall() {
	local trex_ip control
	trex_ip="$(python3 "$TESTBED_DIR/scripts/manifest.py" ip trex)"
	control="$(ip -o route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')"
	iptables -I DOCKER-USER -i "$control" ! -s "$trex_ip" -p tcp \
		-m multiport --dports "$BESSD_PORT,$GUI_PORT,$METRICS_PORT" \
		-m comment --comment upf-testbed -j DROP
}

start() {
	load_ports
	[[ -n "${PORT0_PEER_MAC:-}" ]] || die "ports.env has no peer MACs; rerun startup.sh"
	local tag
	tag="$(image_tag)"
	docker image inspect "upf-bess:$tag" > /dev/null 2>&1 || die "no upf-bess:$tag image; run upf.sh build first"

	"$TESTBED_DIR/scripts/wire.sh" stop
	stop

	rm -rf "$CONF"
	cp -r "$SRC/conf" "$CONF"
	python3 "$TESTBED_DIR/scripts/upf-config.py" "$SRC/conf/upf.jsonc" "$CONF/upf.jsonc"

	docker run --name pause -td --restart unless-stopped \
		-p "$BESSD_PORT:$BESSD_PORT" -p "$GUI_PORT:$GUI_PORT" -p "$METRICS_PORT:$METRICS_PORT" \
		--hostname "$(hostname)" registry.k8s.io/pause > /dev/null
	firewall
	mkdir -p /var/run/netns
	ln -sf "$(docker inspect --format='{{.NetworkSettings.SandboxKey}}' pause)" /var/run/netns/pause

	# Each DPDK port gets a veth in the pause namespace with its name, MAC and
	# PCI address (as the alias, which the BESS pipeline looks up), for ARP and
	# ICMP through the kernel. Neighbors are static: the TRex ports.
	local i pci mac peer
	for i in 0 1; do
		pci="PORT${i}_PCI" mac="PORT${i}_MAC" peer="PORT${i}_PEER_MAC"
		ip netns exec pause ip link add "${IFACES[$i]}" type veth peer name "${IFACES[$i]}-vdev"
		ip netns exec pause ip link set "${IFACES[$i]}" address "${!mac}" alias "${!pci}" up
		ip netns exec pause ip link set "${IFACES[$i]}-vdev" up
		ip netns exec pause ip addr add "${IPADDRS[$i]}" dev "${IFACES[$i]}"
		ip netns exec pause ip neigh replace "${NHIPADDRS[$i]}" lladdr "${!peer}" dev "${IFACES[$i]}"
		ip netns exec pause ip route add "${ROUTES[$i]}" via "${NHIPADDRS[$i]}" metric 100
	done

	local devices=(--device=/dev/vfio/vfio) group cpus
	for pci in $(port_pcis); do
		group="$(basename "$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group")")"
		devices+=("--device=/dev/vfio/$group")
	done
	cpus="$(node_cpus "$PORT0_NUMA" | sed -n 2,3p | paste -sd, -)"

	docker run --name bess -td --restart unless-stopped \
		--cpuset-cpus="$cpus" \
		--ulimit memlock=-1 -v /dev/hugepages:/dev/hugepages \
		-v "$CONF:/opt/bess/bessctl/conf" \
		--net container:pause --cap-add IPC_LOCK "${devices[@]}" \
		"upf-bess:$tag" -grpc-url="0.0.0.0:$BESSD_PORT" > /dev/null
	sleep 10
	if ! docker exec bess ./bessctl run up4 > "$LOGDIR/up4.log" 2>&1; then
		tail -n 30 "$LOGDIR/up4.log"
		docker logs bess 2>&1 | tail -n 30
		die "the up4 pipeline did not start; see $LOGDIR/up4.log"
	fi

	docker run --name bess-web -d --restart unless-stopped \
		--net container:bess --entrypoint bessctl \
		"upf-bess:$tag" http 0.0.0.0 "$GUI_PORT" > /dev/null
	docker run --name bess-pfcp -td --restart on-failure \
		--net container:pause -v "$CONF/upf.jsonc:/conf/upf.jsonc" \
		"upf-pfcp:$tag" -config /conf/upf.jsonc > /dev/null
	docker run --name bess-routectl -td --restart unless-stopped \
		-v "$CONF/route_control.py:/route_control.py" \
		--net container:pause --pid container:bess \
		--entrypoint /route_control.py \
		"upf-bess:$tag" -i "${IFACES[@]}" > /dev/null
	log "UPF is up on CPUs $cpus: access ${PORT0_PCI}, core ${PORT1_PCI}; BESS gRPC on port $BESSD_PORT"
}

status() {
	docker ps --filter name=bess --filter name=pause --format '{{.Names}}\t{{.Status}}'
	docker exec bess ./bessctl show port 2> /dev/null || true
}

case "${1:-}" in
build)
	shift
	build "$@"
	;;
start) start ;;
stop)
	stop
	log "UPF stopped"
	;;
status) status ;;
*) die "usage: upf.sh build [--repo URL] [--ref REF] | start | stop | status" ;;
esac
