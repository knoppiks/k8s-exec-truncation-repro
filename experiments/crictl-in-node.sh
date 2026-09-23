#!/usr/bin/env bash
# Rung 1, done properly: crictl and the slow reader both inside the node.
#
# The original rung 1 ran `docker exec -i <node> crictl exec … | slow reader`
# on the host. The reader was slow, but docker's attach stream sat between it
# and crictl and could absorb the whole payload, so crictl — and therefore
# containerd — may never have seen a slow consumer at all. A clean result from
# that setup does not clear containerd.
#
# Here the throttled reader runs in the node, directly on crictl's stdout, and
# the received byte count is read from a file in the node afterwards. Nothing
# but a pipe sits between crictl and the reader.
#
#   experiments/crictl-in-node.sh --size 32 --runs 5

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"

SIZE=32
RUNS=5
RATE=$((1024 * 1024))
DRAIN=0
CSV=

while (($#)); do
  case "$1" in
    --size) SIZE=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --rate) RATE=$2; shift 2 ;;
    --drain) DRAIN=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=env/kind.sh
source "$REPO_ROOT/env/kind.sh"
: "${CSV:=$REPO_ROOT/results/experiments/crictl-in-node-kind.csv}"
mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] ||
  printf 'env,size_mib,rate,drain,expected_bytes,got_bytes,crictl_exit,seconds,verdict\n' >"$CSV"

node=$POD_NODE
id=$(docker exec "$node" crictl ps --name "$POD" -q | head -1)
[[ -n "$id" ]] || { log "no container named $POD on $node"; exit 1; }

gen="dd if=/dev/zero bs=1048576 count=$SIZE 2>/dev/null | tr '\\0' 'x'"
[[ "$DRAIN" == 0 ]] || gen="$gen; sleep $DRAIN"
expected=$((SIZE * 1024 * 1024))

# The same slow_sink the host-side harness uses, shipped into the node verbatim
# so that the reader under test is byte-for-byte the one every other row used.
throttle=$(<"$REPO_ROOT/lib/throttle.sh")

for run in $(seq 1 "$RUNS"); do
  started=$(date +%s)
  # shellcheck disable=SC2016
  result=$(docker exec "$node" bash -c "
    $throttle
    rm -f /tmp/crictl-out
    crictl exec $id sh -c \"$gen\" | slow_sink $RATE /tmp/crictl-out
    rc=\${PIPESTATUS[0]}
    echo \"\$rc \$(stat -c %s /tmp/crictl-out)\"
    rm -f /tmp/crictl-out
  ")
  ended=$(date +%s)
  read -r rc got <<<"$result"

  if [[ "$got" == "$expected" ]]; then verdict=complete; else verdict=truncated; fi
  printf 'kind,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$SIZE" "$RATE" "$DRAIN" "$expected" "$got" "$rc" "$((ended - started))" "$verdict" >>"$CSV"
  log "$(printf 'crictl in-node run%s: %s of %s, exit %s, %ss -> %s' \
    "$run" "$got" "$expected" "$rc" "$((ended - started))" "$verdict")"
done
