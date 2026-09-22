#!/usr/bin/env bash
# The cluster the defect was observed on: k3s v1.36.4+k3s1, three servers with
# embedded etcd, egress-selector-mode unset (therefore "agent"), flannel
# wireguard-native, Debian 13. Reached over the LAN from a workstation.
#
# This is rung 5 of the ladder and the calibration target of Phase 0.

ENV_NAME=${ENV_NAME:-k8s-a}
RUNG=${RUNG:-5}
RUNNER=kubectl
KUBE_CONTEXT=${KUBE_CONTEXT:-home}
NAMESPACE=${NAMESPACE:-exec-repro}
POD=${POD:-payload}

# shellcheck source=lib/pod.sh
source "$REPO_ROOT/lib/pod.sh"

env_up() {
  apply_payload "" --context "$KUBE_CONTEXT"
  wait_pod_ready --context "$KUBE_CONTEXT"
}

env_down() {
  kubectl --context "$KUBE_CONTEXT" delete -f "$REPO_ROOT/manifests/payload-pod.yaml" \
    --ignore-not-found --wait=false >&2
}

env_describe() {
  local node
  node=$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get pod "$POD" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  printf 'cluster=%s pod_node=%s server=%s\n' \
    "$KUBE_CONTEXT" "${node:-unscheduled}" \
    "$(kubectl --context "$KUBE_CONTEXT" config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}')"
}
