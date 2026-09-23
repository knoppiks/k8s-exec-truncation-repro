#!/usr/bin/env bash
# Client logs for a run that lost bytes.
#
# The last thing asked for in kubernetes#60140, and never supplied, was
# `-v=7` output from a failing transfer. This runs the baseline cell with
# verbosity on until a run truncates, and keeps that run's log.
#
#   experiments/verbose-capture.sh --env kind --size 32 --attempts 5

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
ATTEMPTS=5
VERBOSITY=7

while (($#)); do
  case "$1" in
    --env) ENV_FILE=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    --reader) READER=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --attempts) ATTEMPTS=$2; shift 2 ;;
    --verbosity) VERBOSITY=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=/dev/null
source "$REPO_ROOT/env/$ENV_FILE.sh"

export KUBECTL_VERBOSITY=$VERBOSITY
outdir=$REPO_ROOT/results/experiments/verbose
mkdir -p "$outdir"
expected=$((SIZE * 1024 * 1024))

for transport in ${TRANSPORTS//,/ }; do
  caught=no
  for attempt in $(seq 1 "$ATTEMPTS"); do
    log_file="$outdir/${ENV_NAME}-${transport}-v${VERBOSITY}.log"
    tmp_out=$(mktemp)

    build_exec_argv "dd if=/dev/zero bs=1048576 count=$SIZE 2>/dev/null | tr '\\0' 'x'"
    set +e
    env "$(transport_env "$transport")" \
      timeout --signal=KILL $((120 + SIZE * 4)) "${EXEC_ARGV[@]}" \
      2>"$log_file" | sink "$READER" "$tmp_out"
    set -e

    got=$(stat -c %s "$tmp_out")
    rm -f "$tmp_out"

    if ((got < expected)); then
      {
        printf '\n--- harness note ---\n'
        printf 'transport=%s expected=%s got=%s lost=%s attempt=%s\n' \
          "$transport" "$expected" "$got" "$((expected - got))" "$attempt"
      } >>"$log_file"
      log "$transport: caught a short read on attempt $attempt, lost $((expected - got)) bytes — log in $log_file"
      caught=yes
      break
    fi
    log "$transport: attempt $attempt delivered everything, retrying"
  done
  [[ "$caught" == yes ]] || log "$transport: no short read in $ATTEMPTS attempts, no log kept"
done
