#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# CloudLab startup service for every node: startup.sh trex|wire|none
#
# Runs on every boot. The first boot enables the IOMMU and reboots; later boots
# set up hugepages, bind the experiment ports to vfio-pci and set up the role.

set -euo pipefail
source "$(dirname "$0")/lib.sh"

ROLE="${1:?usage: startup.sh trex|wire|none}"

mkdir -p "$STATE_DIR" /var/log/upf-testbed
exec > >(tee -a /var/log/upf-testbed/startup.log) 2>&1
log "startup.sh $ROLE"

install_packages() {
	[[ -f "$STATE_DIR/packages-done" ]] && return
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -q -y dpdk docker.io ethtool jq numactl pciutils python3-yaml
	# Let the experiment user run docker without sudo.
	local user
	user="$(geni-get user_urn 2>/dev/null | awk -F+ '{ print $NF }')" || true
	[[ -n "$user" ]] && usermod -aG docker "$user"
	touch "$STATE_DIR/packages-done"
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

install_packages
enable_iommu
setup_hugepages
record_ports
bind_ports

case "$ROLE" in
trex) "$TESTBED_DIR/scripts/install-trex.sh" ;;
wire) "$TESTBED_DIR/scripts/wire.sh" start ;;
none) ;;
*) die "unknown role $ROLE" ;;
esac

touch "$STATE_DIR/startup-done"
log "startup.sh $ROLE done"
