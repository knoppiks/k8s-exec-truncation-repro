#!/usr/bin/env bash
# `kubectl cp` over a slow link — the setting the #60140 reports come from.
#
# experiments/kubectl-cp.sh copies to a local disk, which is a fast reader: no
# backlog builds and the copy completes. That is also the setting in which the
# failure could not be reproduced upstream. The reports come from clients that
# are far from the cluster, where the link, not the disk, is the bottleneck.
#
# The slow link is modelled without host privileges: the client runs in its own
# container on the cluster's docker network, with CAP_NET_ADMIN, and polices its
# own ingress with tc. Only the client's download rate changes; the cluster, the
# pod and the kubectl binary are the same as in every other measurement.
#
#   experiments/kubectl-cp-slow-link.sh --size 256 --rate 20mbit --runs 2
#
# kind only: the client reaches the apiserver by the control-plane container's
# name on the `kind` network.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"

SIZE=256
RATE=20mbit
TRANSPORTS=ws,spdy
RUNS=2
KIND_CLUSTER=${KIND_CLUSTER:-exec-repro}
NAMESPACE=${NAMESPACE:-exec-repro}
POD=${POD:-payload}
CLIENT_IMAGE=${CLIENT_IMAGE:-alpine:3.22}
CSV=

while (($#)); do
  case "$1" in
    --size) SIZE=$2; shift 2 ;;
    --rate) RATE=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

: "${CSV:=$REPO_ROOT/results/experiments/kubectl-cp-slow-link-kind.csv}"
mkdir -p "$(dirname "$CSV")"
[[ -f "$CSV" ]] ||
  printf 'env,transport,size_mib,link_rate,expected_bytes,got_bytes,sha_match,exit_code,seconds,verdict\n' >"$CSV"

ctx=kind-$KIND_CLUSTER
kube() { kubectl --context "$ctx" "$@"; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
kind get kubeconfig --name "$KIND_CLUSTER" --internal >"$workdir/kubeconfig"

expected=$((SIZE * 1024 * 1024))
log "producing ${SIZE} MiB in the pod"
kube -n "$NAMESPACE" exec "$POD" -- sh -c \
  "dd if=/dev/zero bs=1048576 count=$SIZE 2>/dev/null | tr '\\0' 'x' > /tmp/big"
expected_sha=$(kube -n "$NAMESPACE" exec "$POD" -- sh -c \
  "sha256sum /tmp/big | cut -d' ' -f1" | tr -d '[:space:]')
log "in-pod digest: $expected_sha, client link: $RATE"

# The client script. Ingress policing drops what exceeds the rate and TCP backs
# off, which is how a thin link behaves from the receiver's side.
cat >"$workdir/client.sh" <<'EOF'
set -u
apk add --no-cache iproute2 >/dev/null 2>&1 || { echo "apk failed" >&2; exit 90; }
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: protocol ip u32 match u32 0 0 \
  police rate "$RATE" burst 64k drop flowid :1
start=$(date +%s)
kubectl --kubeconfig /work/kubeconfig cp --retries=0 \
  "$NAMESPACE/$POD:/tmp/big" /work/big >/dev/null 2>/work/stderr
rc=$?
seconds=$(( $(date +%s) - start ))
# Measured here and the copy deleted here: the container runs as root, and
# whatever it leaves in /work the invoking user cannot remove.
size=$(stat -c %s /work/big 2>/dev/null || echo 0)
sha=$(sha256sum /work/big 2>/dev/null | cut -d' ' -f1)
rm -f /work/big
echo "$rc $seconds $size ${sha:-none}" > /work/result
chmod 666 /work/result /work/stderr 2>/dev/null
EOF

for transport in ${TRANSPORTS//,/ }; do
  case "$transport" in
    ws) ws=true ;;
    spdy) ws=false ;;
    *) printf 'unknown transport: %s\n' "$transport" >&2; exit 64 ;;
  esac
  for run in $(seq 1 "$RUNS"); do
    rm -f "$workdir/result" "$workdir/stderr"
    docker run --rm --network kind --cap-add NET_ADMIN \
      -v "$workdir:/work" \
      -v "$(command -v kubectl):/usr/local/bin/kubectl:ro" \
      -e RATE="$RATE" -e NAMESPACE="$NAMESPACE" -e POD="$POD" \
      -e KUBECTL_REMOTE_COMMAND_WEBSOCKETS="$ws" \
      "$CLIENT_IMAGE" sh /work/client.sh

    read -r rc seconds got got_sha <"$workdir/result"
    if [[ "$got_sha" == "$expected_sha" ]]; then
      sha_match=yes
    else
      sha_match=no
    fi

    if [[ "$got" == "$expected" && "$sha_match" == yes ]]; then
      verdict=complete
    elif ((got < expected)); then
      verdict=truncated
    else
      verdict=corrupt
    fi

    printf 'kind,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$transport" "$SIZE" "$RATE" "$expected" "$got" "$sha_match" \
      "$rc" "$seconds" "$verdict" >>"$CSV"
    log "$(printf '%-4s run%s: %s of %s bytes, exit %s, %ss, stderr %sB -> %s' \
      "$transport" "$run" "$got" "$expected" "$rc" "$seconds" \
      "$(stat -c %s "$workdir/stderr" 2>/dev/null || echo 0)" "$verdict")"
    if [[ -s "$workdir/stderr" ]]; then
      sed 's/^/    stderr: /' "$workdir/stderr" | head -5 >&2
    fi
  done
done

kube -n "$NAMESPACE" exec "$POD" -- rm -f /tmp/big

printf '\n' >&2
awk -F, 'NR > 1 { n[$10]++ } END { for (v in n) printf "%-12s %d\n", v, n[v] }' "$CSV" >&2
