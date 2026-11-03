#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# CloudLab startup service for every node: startup.sh trex|wire|upf|none
#
# Runs on every boot. The first boot enables the IOMMU and reboots; later boots
# set up hugepages, bind the experiment ports to vfio-pci and set up the role.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROLE="${1:?usage: startup.sh trex|wire|upf|none}"

mkdir -p "$STATE_DIR" /var/log/upf-testbed
exec > >(tee -a /var/log/upf-testbed/startup.log) 2>&1
log "startup.sh $ROLE"

# dpdk has dpdk-devbind.py; dpdk-dev has dpdk-testpmd; the UPF build needs
# docker-buildx.
PACKAGES=(dpdk dpdk-dev docker.io docker-buildx ethtool jq numactl pciutils python3-yaml)

install_packages() {
	# Check the packages rather than a marker, so adding one to the list
	# installs it on the next boot or rerun.
	dpkg -s "${PACKAGES[@]}" > /dev/null 2>&1 && return
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -q -y "${PACKAGES[@]}"
	# Let the experiment user run docker without sudo.
	local user
	user="$(geni-get user_urn 2>/dev/null | awk -F+ '{ print $NF }')" || true
	if [[ -n "$user" ]]; then
		usermod -aG docker "$user"
	fi
}

enable_iommu() {
	if grep -q 'intel_iommu=on' /proc/cmdline; then
		return
	fi
	[[ -f "$STATE_DIR/iommu-reboot" ]] && die "rebooted, but the IOMMU is still off"
	log "Enabling the IOMMU and rebooting"
	cat > /etc/default/grub.d/90-upf-testbed.cfg <<-'EOF'
		GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT intel_iommu=on iommu=pt"
	EOF
	update-grub
	touch "$STATE_DIR/iommu-reboot"
	reboot
	exit 0
}

setup_hugepages() {
	# 2 MB pages on every NUMA node; TRex and DPDK allocate on the NIC's node.
	local node
	for node in /sys/devices/system/node/node[0-9]*; do
		echo 4096 > "$node/hugepages/hugepages-2048kB/nr_hugepages"
	done
	mkdir -p /mnt/huge
	mountpoint -q /mnt/huge || mount -t hugetlbfs nodev /mnt/huge
	grep -h . /sys/devices/system/node/node*/hugepages/hugepages-2048kB/nr_hugepages
}

# Find the experiment ports by address and record what we need before binding
# them to vfio-pci, which removes their kernel netdevs. Later boots reuse it.
record_ports() {
	if [[ -f "$PORTS_ENV" ]]; then
		load_ports
		return
	fi
	local control i iface dev
	control="$(ip -o route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')"
	: > "$PORTS_ENV.tmp"
	for i in "${!PORT_SUBNETS[@]}"; do
		iface="$(iface_in_subnet "${PORT_SUBNETS[$i]}")"
		[[ -n "$iface" ]] || die "no interface in ${PORT_SUBNETS[$i]}.0/24"
		[[ "$iface" != "$control" ]] || die "$iface carries the control network"
		dev="$(readlink -f "/sys/class/net/$iface/device")"
		cat >> "$PORTS_ENV.tmp" <<-EOF
			PORT${i}_IFACE=$iface
			PORT${i}_PCI=$(basename "$dev")
			PORT${i}_MAC=$(cat "/sys/class/net/$iface/address")
			PORT${i}_NUMA=$(cat "$dev/numa_node")
			PORT${i}_DRIVER=$(basename "$(readlink -f "$dev/driver")")
			PORT${i}_FIRMWARE="$(ethtool -i "$iface" | awk -F': ' '/^firmware-version/ { print $2 }')"
		EOF
	done
	mv "$PORTS_ENV.tmp" "$PORTS_ENV"
	cat "$PORTS_ENV"
	load_ports
}

# The MACs at the far end of each link, for TRex's and the UPF's neighbors.
record_peers() {
	grep -q PORT0_PEER_MAC "$PORTS_ENV" && return
	python3 "$TESTBED_DIR/scripts/manifest.py" peers "$(hostname -s)" >> "$PORTS_ENV"
	load_ports
}

bind_ports() {
	modprobe vfio-pci
	local pci group dev
	for pci in $(port_pcis); do
		# vfio needs every device in the IOMMU group bound to it, so refuse
		# to bind if the group holds anything else.
		group="$(readlink -f "/sys/bus/pci/devices/$pci/iommu_group")"
		for dev in "$group"/devices/*; do
			[[ "$(basename "$dev")" == "$pci" ]] && continue
			case " $(port_pcis) " in
			*" $(basename "$dev") "*) ;;
			*) die "$pci shares IOMMU group $(basename "$group") with $(basename "$dev")" ;;
			esac
		done
		ip link set "$(ls "/sys/bus/pci/devices/$pci/net" 2>/dev/null)" down 2>/dev/null || true
	done
	# shellcheck disable=SC2046
	devbind --bind=vfio-pci $(port_pcis)
	devbind --status-dev net
}

# DDP profiles change how an Intel 700-series NIC parses packets, and they
# survive reboots and image reloads until a power cycle. TRex loads one in
# hardware mode, so a node can arrive with one left by a previous user.
check_ddp() {
	[[ "$PORT0_DRIVER" == i40e ]] || return 0
	local cpus profiles
	cpus="$(node_cpus "$PORT0_NUMA" | head -n 2 | paste -sd, -)"
	profiles="$(printf 'ddp get list 0\nddp get list 1\nquit\n' |
		timeout 60 dpdk-testpmd -l "$cpus" -n 4 -a "$PORT0_PCI" -a "$PORT1_PCI" \
			--file-prefix ddp-check -- -i 2>&1 | grep -E 'Profile (number|name)')" || true
	echo "$profiles"
	if grep -q 'Profile name' <<< "$profiles"; then
		log "WARNING: a DDP profile is loaded on the experiment ports; power-cycle this node from the CloudLab portal to clear it"
	fi
}

install_packages
enable_iommu
setup_hugepages
record_ports
record_peers
bind_ports
check_ddp

case "$ROLE" in
trex) "$TESTBED_DIR/scripts/install-trex.sh" ;;
wire) "$TESTBED_DIR/scripts/wire.sh" start ;;
# upf.sh builds and starts the UPF on demand; see docs/phase2.md.
upf | none) ;;
*) die "unknown role $ROLE" ;;
esac

touch "$STATE_DIR/startup-done"
log "startup.sh $ROLE done"
