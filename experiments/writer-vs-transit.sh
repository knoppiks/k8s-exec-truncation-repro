#!/usr/bin/env bash
# Were the bytes discarded, or was the writer killed?
#
# Both produce a short read at the client, and they are different defects. If
# the stream teardown closes the container's stdout, the process writing into
# it dies of SIGPIPE (exit 141) and the bug is "exec kills a process that is
# still writing". If the writer exits 0 and the client still comes up short,
# the bytes were accepted from the container and lost after that.
#
# The payload is written to a file first, so that production and streaming are
# separate events and the writer's fate can be read afterwards from inside the
# container, by an exec whose own output is a few bytes.
#
#   experiments/writer-vs-transit.sh --env kind --size 32 --runs 5

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
SIZE=32
READER=slow
TRANSPORTS=ws,spdy
RUNS=5
CSV=

while (($#)); do
  case "$1" in
    --env) ENV_FILE=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    --reader) READER=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=/dev/null
source "$REPO_ROOT/env/$ENV_FILE.sh"
: "${CSV:=$REPO_ROOT/results/experiments/writer-vs-transit-$ENV_NAME.csv}"

mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] ||
  printf 'env,transport,size_mib,reader,expected_bytes,got_bytes,produced_bytes,writer_exit,verdict\n' >"$CSV"

# Produce into a file, stream the file, then record what happened to the
# streaming process. `cat` is the writer under test; its exit status is the
# whole point of the experiment.
stream_and_record() {
  printf '%s\n' "
    rm -f /tmp/writer-exit
    dd if=/dev/zero bs=1048576 count=$SIZE 2>/dev/null | tr '\\0' 'x' > /tmp/payload
    cat /tmp/payload
    echo \$? > /tmp/writer-exit
  "
}

expected=$((SIZE * 1024 * 1024))
outdir=$REPO_ROOT/results/experiments/artifacts
mkdir -p "$outdir"

for transport in ${TRANSPORTS//,/ }; do
  for run in $(seq 1 "$RUNS"); do
    out="$outdir/writer-${ENV_NAME}-${transport}-run${run}.bin"

    build_exec_argv "$(stream_and_record)"
    set +e
    env "$(transport_env "$transport")" \
      timeout --signal=KILL $((120 + SIZE * 4)) "${EXEC_ARGV[@]}" \
      2>/dev/null | sink "$READER" "$out"
    set -e
    got=$(stat -c %s "$out")
    rm -f "$out"

    # A second, tiny exec: two numbers, eighty bytes, over the same path.
    build_exec_argv "cat /tmp/writer-exit 2>/dev/null || echo missing; wc -c < /tmp/payload"
    readarray -t after < <("${EXEC_ARGV[@]}" 2>/dev/null | tr -d '\r')
    writer_exit=${after[0]:-unknown}
    produced=${after[1]:-unknown}

    if [[ "$got" == "$expected" ]]; then
      verdict=complete
    elif [[ "$writer_exit" == 0 ]]; then
      verdict=lost-after-writer
    elif [[ "$writer_exit" == 141 ]]; then
      verdict=writer-killed-sigpipe
    else
      verdict="writer-exit-$writer_exit"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ENV_NAME" "$transport" "$SIZE" "$READER" \
      "$expected" "$got" "$produced" "$writer_exit" "$verdict" >>"$CSV"
    log "$(printf '%-6s run%s: got %s of %s, produced %s, writer exit %s -> %s' \
      "$transport" "$run" "$got" "$expected" "$produced" "$writer_exit" "$verdict")"
  done
done

printf '\n' >&2
awk -F, 'NR > 1 { n[$9]++ } END { for (v in n) printf "%-24s %d\n", v, n[v] }' "$CSV" >&2
