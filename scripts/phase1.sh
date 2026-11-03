#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Phase 1: send from TRex port 1 through the wire on the UPF node and count
# what comes back on port 0, for each combination of DP cores, memory config
# and payload. Run on the trex node, with wire.sh running on the upf node.
#
# Uses ptf/trex-rx-repro.py and the PTF image (TRex v3.06 client) from a UPF
# checkout, so the client matches what the PTF tests use.

set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

UPF_REPO=https://github.com/andybavier/upf
UPF_REF=scratch/trex-fe-repro
CORES="1 2"
MEMORY="ptf default"
PAYLOADS="plain gtpu"
PPS=10000
RUNS=2
DURATION=10

usage() {
	cat <<-EOF
		usage: phase1.sh [options]
		  --upf-repo URL     UPF repository ($UPF_REPO)
		  --upf-ref REF      branch or commit with ptf/trex-rx-repro.py ($UPF_REF)
		  --cores "N ..."    DP core counts to try ($CORES)
		  --memory "M ..."   ptf (the PTF config's pools) and/or default ($MEMORY)
		  --payloads "P ..." plain and/or gtpu ($PAYLOADS)
		  --pps N            packets per second ($PPS)
		  --runs N           runs per TRex start ($RUNS)
		  --duration S       seconds per run ($DURATION)
	EOF
	exit 1
}

while (($#)); do
	case "$1" in
	--upf-repo) UPF_REPO="$2" ;;
	--upf-ref) UPF_REF="$2" ;;
	--cores) CORES="$2" ;;
	--memory) MEMORY="$2" ;;
	--payloads) PAYLOADS="$2" ;;
	--pps) PPS="$2" ;;
	--runs) RUNS="$2" ;;
	--duration) DURATION="$2" ;;
	*) usage ;;
	esac
	shift 2
done

# CloudLab names each host after its node in profile.py.
[[ "$(hostname -s)" == trex ]] || die "run phase1.sh on the trex node, not $(hostname -s)"

SRC="$STATE_DIR/src/upf"
OUT="$STATE_DIR/results/phase1/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
log "Results go to $OUT"

# Installs TRex if the startup service didn't; does nothing if it did.
"$TESTBED_DIR/scripts/install-trex.sh"
[[ -x "$TREX_DIR/t-rex-64" ]] || die "TRex is not installed in $TREX_DIR"

# Check out the UPF and build its PTF image.
if [[ ! -d "$SRC/.git" ]]; then
	git clone -q "$UPF_REPO" "$SRC"
fi
git -C "$SRC" fetch -q "$UPF_REPO" "$UPF_REF"
git -C "$SRC" checkout -q --detach FETCH_HEAD
[[ -f "$SRC/ptf/trex-rx-repro.py" ]] || die "$UPF_REF has no ptf/trex-rx-repro.py"
make -C "$SRC/ptf" image > "$OUT/ptf-image.log" 2>&1 ||
	die "PTF image build failed; see $OUT/ptf-image.log"

# Record the host, NIC and software versions next to the results.
{
	echo "upf: $UPF_REPO $UPF_REF $(git -C "$SRC" rev-parse HEAD)"
	echo "trex server: $(cat "$TREX_DIR/.testbed-version")"
	echo "kernel: $(uname -r)"
	echo "cmdline: $(cat /proc/cmdline)"
	echo
	cat "$PORTS_ENV"
	echo
	devbind --status-dev net
	echo
	lscpu
} > "$OUT/host.txt"
cp "$SRC/ptf/config/trex-cfg-for-ptf.yaml" "$OUT/"

repro() {
	docker run --rm --network host \
		-v "$SRC/ptf:/upf-tests:ro" \
		bess-upf-ptf \
		sh -ec 'PYTHONPATH="/upf-tests/lib:/upf-tests/tests/linerate:${PYTHONPATH}" exec python3 /upf-tests/trex-rx-repro.py "$@"' \
		trex-rx-repro "$@"
}

# Per-thread CPU use partway through the first run shows whether every DP
# thread is polling.
sample_threads() {
	sleep $((DURATION / 2 + 2))
	top -H -b -n 2 -d 2 -p "$(pgrep -f _t-rex-64 | head -n 1)" > "$1" 2>&1 || true
}

for memory in $MEMORY; do
	memory_args=()
	[[ "$memory" == ptf ]] && memory_args=(--memory-from "$OUT/trex-cfg-for-ptf.yaml")
	for cores in $CORES; do
		for payload in $PAYLOADS; do
			name="c$cores-$memory-$payload"
			log "Running $name"
			# Restart TRex for every combination so each starts with full pools.
			if ! "$TESTBED_DIR/scripts/trex.sh" start --cores "$cores" \
				"${memory_args[@]}" --log "$OUT/trex-$name.log"; then
				log "TRex failed to start for $name"
				continue
			fi
			cp "$TREX_DIR/trex_cfg.yaml" "$OUT/trex-cfg-$name.yaml"
			sample_threads "$OUT/threads-$name.txt" &
			repro run --payload "$payload" --pps "$PPS" --runs "$RUNS" \
				--duration "$DURATION" | tee "$OUT/$name.txt" || true
			wait
			"$TESTBED_DIR/scripts/trex.sh" stop
		done
	done
done

{
	echo "## TRex port 0 receive, $PPS pps for ${DURATION}s per run"
	echo
	echo '| cores | memory | payload | run | sent | received | ierrors | latency samples | rx xstats |'
	echo '|---|---|---|---|---|---|---|---|---|'
	for memory in $MEMORY; do
		for cores in $CORES; do
			for payload in $PAYLOADS; do
				name="c$cores-$memory-$payload"
				grep -h '^{' "$OUT/$name.txt" 2> /dev/null |
					jq -r --arg c "$cores" --arg m "$memory" \
						'"| \($c) | \($m) | \(.payload) | \(.run) | \(.sent) | \(.received) | \(.ierrors) | \(.latency_samples) | \(.rx_xstats | tojson) |"' ||
					echo "| $cores | $memory | $payload | - | no result | | | | |"
			done
		done
	done
} | tee "$OUT/summary.md"
log "Results are in $OUT"
