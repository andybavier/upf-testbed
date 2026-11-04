#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ptf.sh [options] unary|linerate [TEST]
#
# Run the UPF's PTF tests from the trex node against the UPF that upf.sh runs
# on the upf node. Checks out the UPF, adapts its PTF config to this testbed
# (what ptf/README.md step 1 asks for), builds the PTF image if needed, starts
# the TRex daemon and runs ptf/run_tests. Records the TRex statistics the
# linerate tests read (scripts/ptf-metrics.py), for compare.py.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

UPF_REPO=https://github.com/omec-project/upf
UPF_REF=main
FETCH=1
AVX2_RX=()
LABEL=

usage() {
	cat <<-EOF
		usage: ptf.sh [options] unary|linerate [TEST]
		  --upf-repo URL   UPF repository ($UPF_REPO)
		  --upf-ref REF    branch or commit to test ($UPF_REF)
		  --label NAME     results directory name (default: REF, / -> _)
		  --no-fetch       test the checkout as it is
		  --avx2-rx        remove the trex-core#1182 SIMD cap, even the branch's
		TEST is a test file or file.TestCase within the suite, e.g. baseline.
	EOF
	exit 1
}

while (($#)); do
	case "$1" in
	--upf-repo) UPF_REPO="$2" && shift ;;
	--upf-ref) UPF_REF="$2" && shift ;;
	--label) LABEL="$2" && shift ;;
	--no-fetch) FETCH=0 ;;
	--avx2-rx) AVX2_RX=(--avx2-rx) ;;
	-*) usage ;;
	*) break ;;
	esac
	shift
done
SUITE="${1:-}"
TEST="${2:-}"
[[ "$SUITE" == unary || "$SUITE" == linerate ]] || usage
[[ "$(hostname -s)" == trex ]] || die "run ptf.sh on the trex node, not $(hostname -s)"
load_ports
[[ -n "${PORT0_PEER_MAC:-}" ]] || die "ports.env has no peer MACs; rerun startup.sh"

SRC="$STATE_DIR/src/upf"
LABEL="${LABEL:-${UPF_REF//\//_}}"
OUT="$STATE_DIR/results/$LABEL/$(date -u +%Y%m%dT%H%M%SZ)-$SUITE${TEST:+-$TEST}"
mkdir -p "$OUT"
log "Results go to $OUT"

# Check out the UPF, discarding the previous run's local config edits.
if ((FETCH)); then
	[[ -d "$SRC/.git" ]] || git clone -q "$UPF_REPO" "$SRC"
	git -C "$SRC" fetch -q "$UPF_REPO" "$UPF_REF"
	git -C "$SRC" reset -q --hard
	git -C "$SRC" checkout -q --detach FETCH_HEAD
fi
git -C "$SRC" reset -q --hard

# Build the PTF image and BESS Python protobufs if this commit doesn't have them.
commit="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$(cat "$STATE_DIR/ptf-image-commit" 2> /dev/null)" != "$commit" ]] ||
	! docker image inspect bess-upf-ptf > /dev/null 2>&1; then
	log "Building the PTF image; log in /var/log/upf-testbed/ptf-build.log"
	make -C "$SRC/ptf" build > /var/log/upf-testbed/ptf-build.log 2>&1 ||
		die "PTF build failed; see /var/log/upf-testbed/ptf-build.log"
	echo "$commit" > "$STATE_DIR/ptf-image-commit"
fi

# Adapt the PTF config to this testbed: TRex's ports and threads, and the MACs
# of both ends of each link. Keep the repo's DP core count, memory pools and
# DPDK options (the trex-core#1182 SIMD cap); older branches without the cap
# get the testbed's.
cfg="$SRC/ptf/config/trex-cfg-for-ptf.yaml"
orig="$OUT/trex-cfg-for-ptf.orig.yaml"
cp "$cfg" "$orig"
read -r cores simd_cap < <(python3 -c '
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))[0]
print(c["c"], "branch" if "ext_dpdk_opt" in c else "testbed")' "$orig")
python3 "$TESTBED_DIR/scripts/trex-config.py" --cores "$cores" --memory-from "$orig" \
	--dpdk-opts-from "$orig" "${AVX2_RX[@]}" --out "$cfg" > /dev/null
# shellcheck disable=SC2153 # PORT1_PEER_MAC comes from ports.env
sed -i \
	-e "s/^TREX_SRC_MAC = \"[^\"]*\"/TREX_SRC_MAC = \"$PORT1_MAC\"/" \
	-e "s/^UPF_CORE_MAC = \"[^\"]*\"/UPF_CORE_MAC = \"$PORT1_PEER_MAC\"/" \
	-e "s/^UPF_ACCESS_MAC = \"[^\"]*\"/UPF_ACCESS_MAC = \"$PORT0_PEER_MAC\"/" \
	"$SRC/ptf/tests/linerate/common.py"
# Record the TRex statistics the tests read; see scripts/ptf-metrics.py.
cat "$TESTBED_DIR/scripts/ptf-metrics.py" >> "$SRC/ptf/lib/trex_utils.py"
git -C "$SRC" diff > "$OUT/localization.diff"
# ptf/log isn't tracked, so clear the previous run's logs and metrics.
rm -rf "$SRC/ptf/log"

# ptf_runner.py drives TRex through its daemon, which starts the server with
# the config above. The PTF container reaches it through docker0.
"$TESTBED_DIR/scripts/install-trex.sh"
"$TESTBED_DIR/scripts/trex.sh" stop
if ! ss -ltn | grep -q ':8090 '; then
	(cd "$TREX_DIR" && ./trex_daemon_server start) > "$OUT/trex-daemon-start.log" 2>&1 || true
	sleep 5
	ss -ltn | grep -q ':8090 ' || {
		cat "$OUT/trex-daemon-start.log"
		die "the TRex daemon did not start"
	}
fi
# Keep TRex's control ports off the public control network.
control="$(ip -o route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')"
for port in 4500 4501 8090; do
	iptables -C INPUT -i "$control" -p tcp --dport "$port" -j DROP 2> /dev/null ||
		iptables -I INPUT -i "$control" -p tcp --dport "$port" -j DROP
done

upf_ip="$(python3 "$TESTBED_DIR/scripts/manifest.py" ip upf)"
trex_ip="$(ip -4 -o addr show docker0 | awk '{ split($4, a, "/"); print a[1] }')"
{
	echo "upf: $UPF_REPO $UPF_REF $commit"
	echo "trex server: $(cat "$TREX_DIR/.testbed-version")"
	echo "UPF_ADDR=$upf_ip:10514 TREX_ADDR=$trex_ip"
	if ((${#AVX2_RX[@]})); then
		echo "SIMD cap: removed (--avx2-rx)"
	else
		echo "SIMD cap: from the $simd_cap config"
	fi
	cat "$PORTS_ENV"
} > "$OUT/host.txt"

log "Running tests/$SUITE${TEST:+ $TEST} against $upf_ip"
status=0
(cd "$SRC/ptf" && UPF_ADDR="$upf_ip:10514" TREX_ADDR="$trex_ip" \
	./run_tests -t "tests/$SUITE" ${TEST:+"$TEST"}) 2>&1 | tee "$OUT/run.log" || status=$?

cp -r "$SRC/ptf/log/." "$OUT/ptf-log/" 2> /dev/null || true
cp /tmp/trex.txt "$OUT/trex-server.txt" 2> /dev/null || true
log "Results are in $OUT"
exit "$status"
