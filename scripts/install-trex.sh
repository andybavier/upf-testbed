#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Install the TRex server release $TREX_VERSION (default v3.08) in /opt/trex.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

if [[ "$(cat "$TREX_DIR/.testbed-version" 2>/dev/null)" == "$TREX_VERSION" ]]; then
	log "TRex $TREX_VERSION is already in $TREX_DIR"
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# trex-tgn.cisco.com omits its intermediate certificate, so fetch it from the
# issuer (the leaf's AIA URL) and verify against it too.
curl -fsSL --retry 3 -o "$work/hydrantid.p7c" \
	http://validation.identrust.com/certs/hydrantidcaO1.p7c
openssl pkcs7 -inform DER -print_certs -in "$work/hydrantid.p7c" |
	cat /etc/ssl/certs/ca-certificates.crt - > "$work/ca-bundle.crt"
log "Downloading TRex $TREX_VERSION"
curl -fsSL --retry 3 --cacert "$work/ca-bundle.crt" -o "$work/trex.tar.gz" \
	"https://trex-tgn.cisco.com/trex/release/$TREX_VERSION.tar.gz"

# Some TRex helpers run as nobody, so TRex can't live under a home directory.
rm -rf "$TREX_DIR"
mkdir -p "$TREX_DIR"
tar -xzf "$work/trex.tar.gz" -C "$TREX_DIR" --strip-components=1
# TRex's bundled libstdc++ is older than the system one that other libraries
# on the host need.
rm -f "$TREX_DIR/so/x86_64/libstdc++.so.6"
echo "$TREX_VERSION" > "$TREX_DIR/.testbed-version"
log "Installed TRex $TREX_VERSION in $TREX_DIR"
