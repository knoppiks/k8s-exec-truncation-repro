#!/usr/bin/env bash
# Is the missing region at the end, or is there a hole in the middle?
#
# The `x`-filled payload proves how much was lost and proves nothing about
# where. A counter stream does both: every line states its own position, so a
# short read is either 1..k with the tail missing — consistent with teardown
# at the end of the stream — or contiguous with a gap, which would mean frames
# were dropped while the connection stayed up. The two want different fixes.
#
#   experiments/where-is-the-hole.sh --env kind --lines 4000000 --runs 3

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/throttle.sh
source "$REPO_ROOT/lib/throttle.sh"
# shellcheck source=lib/run.sh
source "$REPO_ROOT/lib/run.sh"

ENV_FILE=kind
LINES=4000000
READER=slow
TRANSPORTS=ws,spdy
RUNS=3
CSV=

while (($#)); do
  case "$1" in
    --env) ENV_FILE=$2; shift 2 ;;
    --lines) LINES=$2; shift 2 ;;
    --reader) READER=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=/dev/null
source "$REPO_ROOT/env/$ENV_FILE.sh"
: "${CSV:=$REPO_ROOT/results/experiments/where-is-the-hole-$ENV_NAME.csv}"

mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] ||
  printf 'env,transport,lines_expected,bytes_expected,bytes_got,lines_got,last_value,first_gap_at,tail_partial,verdict\n' >"$CSV"

# `seq` is the payload kubernetes#60140 already argues about, and it is legible:
# line N contains N.
expected_bytes=$(seq 1 "$LINES" | wc -c)
outdir=$REPO_ROOT/results/experiments/artifacts
mkdir -p "$outdir"

for transport in ${TRANSPORTS//,/ }; do
  for run in $(seq 1 "$RUNS"); do
    out="$outdir/hole-${ENV_NAME}-${transport}-run${run}.txt"

    build_exec_argv "seq 1 $LINES"
    set +e
    env "$(transport_env "$transport")" \
      timeout --signal=KILL 900 "${EXEC_ARGV[@]}" 2>/dev/null | sink "$READER" "$out"
    set -e

    bytes_got=$(stat -c %s "$out")
    lines_got=$(wc -l <"$out")
    last_value=$(tail -1 "$out" | tr -d '[:space:]')

    # The first line whose value does not equal its position. Anything other
    # than "none" means the stream had a hole in it rather than a cut end.
    first_gap=$(awk 'NR != $1 { print NR; exit }' "$out")
    first_gap=${first_gap:-none}

    # A final line without its newline is a cut in mid-number: the tail was
    # severed, not dropped as a unit.
    if [[ -s "$out" ]] && [[ -n "$(tail -c 1 "$out")" ]]; then
      tail_partial=yes
    else
      tail_partial=no
    fi

    if ((bytes_got == expected_bytes)); then
      verdict=complete
    elif [[ "$first_gap" == none ]]; then
      verdict=tail-cut
    else
      verdict=hole-in-middle
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ENV_NAME" "$transport" "$LINES" "$expected_bytes" "$bytes_got" \
      "$lines_got" "$last_value" "$first_gap" "$tail_partial" "$verdict" >>"$CSV"
    log "$(printf '%-6s run%s: %s of %s bytes, last value %s, first gap %s, partial tail %s -> %s' \
      "$transport" "$run" "$bytes_got" "$expected_bytes" "$last_value" \
      "$first_gap" "$tail_partial" "$verdict")"

    # Keep only the last kilobyte: the verdict is in the numbers above.
    tail -c 1024 "$out" >"$out.tail"
    rm -f "$out"
  done
done

printf '\n' >&2
awk -F, 'NR > 1 { n[$10]++ } END { for (v in n) printf "%-16s %d\n", v, n[v] }' "$CSV" >&2
