#!/usr/bin/env bash
# The control group: vanilla Kubernetes on containerd, no k3s, no remotedialer.
#
# If kind truncates too, nothing about this defect is k3s-specific. If kind is
# clean where k3s is not, the difference between them is the finding.
#
# kind also runs containerd, so it does not control for the runtime — only for
# the distribution. A second control on CRI-O would close that gap and is not
# here yet; the README says so.

ENV_NAME=${ENV_NAME:-kind}
RUNG=${RUNG:-3}
RUNNER=${RUNNER:-kubectl}
NAMESPACE=${NAMESPACE:-exec-repro}
POD=${POD:-payload}
KIND_CLUSTER=${KIND_CLUSTER:-exec-repro}
NETEM_NETWORK=${NETEM_NETWORK:-kind}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$KIND_CLUSTER}
POD_NODE=${POD_NODE:-${KIND_CLUSTER}-worker}

# shellcheck source=lib/pod.sh
source "$REPO_ROOT/lib/pod.sh"

env_up() {
  if ! kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1; then
    command -v kind >/dev/null 2>&1 || {
      log "kind is not installed and the cluster does not exist"
      return 1
    }
    local -a image=()
    [[ -n "${KIND_NODE_IMAGE:-}" ]] && image=(--image "$KIND_NODE_IMAGE")
    kind create cluster --name "$KIND_CLUSTER" \
      --config "$REPO_ROOT/env/kind-cluster.yaml" "${image[@]}" --wait 180s >&2
  fi
  apply_payload "$POD_NODE" --context "$KUBE_CONTEXT"
  wait_pod_ready --context "$KUBE_CONTEXT"
}

env_down() {
  if command -v kind >/dev/null 2>&1 &&
    kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
    kind delete cluster --name "$KIND_CLUSTER" >&2
  fi
}

env_describe() {
  printf 'kind=%s node=%s server=%s\n' "$KIND_CLUSTER" "$POD_NODE" \
    "$(kubectl --context "$KUBE_CONTEXT" config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
}

# Rung 1 for kind: containerd's streaming server on the worker node container.
use_crictl() {
  CRICTL_DOCKER=$POD_NODE
  CRICTL_CMD=crictl
  local id
  id=$(docker exec "$CRICTL_DOCKER" crictl ps --name "$POD" -q 2>/dev/null | head -1)
  [[ -n "$id" ]] || { log "no running container named $POD on $CRICTL_DOCKER"; return 1; }
  CRICTL_ID=$id
  RUNNER=crictl
  RUNG=1
}
