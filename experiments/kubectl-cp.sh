#!/usr/bin/env bash
# The symptom kubernetes#60140 is named after.
#
# `kubectl cp` is `kubectl exec ... tar cf -` with a tar reader on the near
# end, so if exec loses bytes then cp loses files. This measures cp directly:
# a file of known size and digest is produced in the pod, copied out, and
# compared. No throttling — cp's reader is a local disk, and the point is to
# find out whether a plain copy of a large file is safe today.
#
#   experiments/kubectl-cp.sh --env kind --size 1024 --runs 3

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/run.sh
source "$REPO_ROOT/lib/run.sh"

ENV_FILE=kind
SIZE=1024
TRANSPORTS=ws,spdy
RUNS=3
CSV=
WORKDIR=${TMPDIR:-/tmp}/kubectl-cp-experiment

while (($#)); do
  case "$1" in
    --env) ENV_FILE=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=/dev/null
source "$REPO_ROOT/env/$ENV_FILE.sh"
: "${CSV:=$REPO_ROOT/results/experiments/kubectl-cp-$ENV_NAME.csv}"

mkdir -p "$(dirname "$CSV")" "$WORKDIR"
[[ -f "$CSV" ]] ||
  printf 'env,transport,size_mib,expected_bytes,got_bytes,sha_match,exit_code,seconds,verdict\n' >"$CSV"

kube() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

expected=$((SIZE * 1024 * 1024))

log "producing ${SIZE} MiB in the pod"
kube -n "$NAMESPACE" exec "$POD" -- sh -c \
  "dd if=/dev/zero bs=1048576 count=$SIZE 2>/dev/null | tr '\\0' 'x' > /tmp/big"
expected_sha=$(kube -n "$NAMESPACE" exec "$POD" -- sh -c \
  "sha256sum /tmp/big | cut -d' ' -f1" | tr -d '[:space:]')
log "in-pod digest: $expected_sha"

for transport in ${TRANSPORTS//,/ }; do
  for run in $(seq 1 "$RUNS"); do
    dest="$WORKDIR/big-${transport}-${run}"
    rm -f "$dest"
    started=$(date +%s)
    set +e
    # `kube` is a function, so the transport is exported into a subshell rather
    # than prefixed with env(1).
    (
      export "$(transport_env "$transport")"
      kube cp "$NAMESPACE/$POD:/tmp/big" "$dest" --retries=0 >/dev/null 2>&1
    )
    rc=$?
    set -e
    ended=$(date +%s)

    got=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    if [[ "$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)" == "$expected_sha" ]]; then
      sha_match=yes
    else
      sha_match=no
    fi
    rm -f "$dest"

    if [[ "$got" == "$expected" && "$sha_match" == yes ]]; then
      verdict=complete
    elif ((got < expected)); then
      verdict=truncated
    else
      verdict=corrupt
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$ENV_NAME" "$transport" "$SIZE" "$expected" "$got" "$sha_match" \
      "$rc" "$((ended - started))" "$verdict" >>"$CSV"
    log "$(printf '%-4s run%s: %s of %s bytes, exit %s, %ss -> %s' \
      "$transport" "$run" "$got" "$expected" "$rc" "$((ended - started))" "$verdict")"
  done
done

kube -n "$NAMESPACE" exec "$POD" -- rm -f /tmp/big
rmdir "$WORKDIR" 2>/dev/null || true

printf '\n' >&2
awk -F, 'NR > 1 { n[$9]++ } END { for (v in n) printf "%-12s %d\n", v, n[v] }' "$CSV" >&2
