#!/usr/bin/env bash
# A throwaway k3s in plain docker: one server, one agent.
#
# Not k3d. Raw containers give exact version pinning, arbitrary server flags and
# nothing else installed, which is what a bisection needs. Two containers rather
# than three because the workstation has to keep running.
#
# Knobs, all via environment:
#   K3S_VERSION   image tag, e.g. v1.36.4-k3s1 (production is v1.36.4+k3s1)
#   EGRESS        agent | disabled — the k3s remotedialer tunnel, on or off
#   POD_NODE      agent | server   — where the payload pod runs
#   API_PORT      host port for the apiserver

ENV_NAME=${ENV_NAME:-k3s-docker}
RUNG=${RUNG:-3}
RUNNER=${RUNNER:-kubectl}
NAMESPACE=${NAMESPACE:-exec-repro}
POD=${POD:-payload}

K3S_VERSION=${K3S_VERSION:-v1.36.4-k3s1}
EGRESS=${EGRESS:-agent}
POD_NODE=${POD_NODE:-agent}
API_PORT=${API_PORT:-16443}
K3S_TOKEN_VALUE=${K3S_TOKEN_VALUE:-exec-repro}

NET=k3s-repro
NETEM_NETWORK=$NET
SERVER=k3s-repro-server
AGENT=k3s-repro-agent
KUBECONFIG_PATH=${KUBECONFIG_PATH:-/tmp/k3s-repro.kubeconfig}

# The whole environment talks to this cluster, including the grid, which never
# calls env_up. Exported here rather than there so a grid against an already
# running cluster addresses the same apiserver.
export KUBECONFIG="$KUBECONFIG_PATH"
unset KUBE_CONTEXT

# shellcheck source=lib/pod.sh
source "$REPO_ROOT/lib/pod.sh"

k() { kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

env_up() {
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >&2

  if ! docker inspect "$SERVER" >/dev/null 2>&1; then
    log "starting server: k3s $K3S_VERSION, egress-selector-mode=$EGRESS"
    docker run -d --name "$SERVER" --hostname "$SERVER" \
      --privileged --network "$NET" \
      --tmpfs /run --tmpfs /var/run \
      -e K3S_TOKEN="$K3S_TOKEN_VALUE" \
      -p "127.0.0.1:${API_PORT}:6443" \
      "rancher/k3s:${K3S_VERSION}" \
      server \
      --node-name=server \
      --egress-selector-mode="$EGRESS" \
      --disable=traefik --disable=servicelb --disable=metrics-server \
      --disable=local-storage --disable-helm-controller \
      --disable-cloud-controller >/dev/null
  fi

  wait_for_kubeconfig
  wait_for_node server

  if ! docker inspect "$AGENT" >/dev/null 2>&1; then
    log "starting agent"
    docker run -d --name "$AGENT" --hostname "$AGENT" \
      --privileged --network "$NET" \
      --tmpfs /run --tmpfs /var/run \
      -e K3S_URL="https://${SERVER}:6443" \
      -e K3S_TOKEN="$K3S_TOKEN_VALUE" \
      "rancher/k3s:${K3S_VERSION}" \
      agent --node-name=agent >/dev/null
  fi
  wait_for_node agent

  apply_payload "$POD_NODE" --kubeconfig "$KUBECONFIG_PATH"
  wait_pod_ready --kubeconfig "$KUBECONFIG_PATH"
}

wait_for_kubeconfig() {
  local i
  for i in $(seq 1 120); do
    if docker cp "$SERVER:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_PATH" 2>/dev/null; then
      sed -i "s#https://127.0.0.1:6443#https://127.0.0.1:${API_PORT}#" "$KUBECONFIG_PATH"
      chmod 600 "$KUBECONFIG_PATH"
      return 0
    fi
    sleep 2
  done
  log "kubeconfig never appeared in $SERVER"
  return 1
}

wait_for_node() {
  local node="$1" i
  for i in $(seq 1 150); do
    if k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null |
      grep -q True; then
      return 0
    fi
    sleep 2
  done
  log "node $node never became Ready"
  k get nodes >&2 || true
  return 1
}

env_down() {
  docker rm -f "$SERVER" "$AGENT" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -f "$KUBECONFIG_PATH"
}

env_describe() {
  export KUBECONFIG="$KUBECONFIG_PATH"
  printf 'k3s=%s egress=%s pod_node=%s runner=%s\n' \
    "$K3S_VERSION" "$EGRESS" "$POD_NODE" "$RUNNER"
}

# --------------------------------------------------------- rung plumbing ----

# node_container NODE — the docker container that is that k3s node.
node_container() {
  case "$1" in
    server) printf '%s\n' "$SERVER" ;;
    agent) printf '%s\n' "$AGENT" ;;
  esac
}

# use_crictl — rung 1: talk to containerd's streaming server directly, on the
# node that hosts the pod. No kubelet, no apiserver, no tunnel, no LAN.
use_crictl() {
  export KUBECONFIG="$KUBECONFIG_PATH"
  CRICTL_DOCKER=$(node_container "$POD_NODE")
  # The image symlinks /bin/crictl to the k3s binary; `k3s crictl` is not a
  # subcommand and answers "No help topic for 'crictl'".
  CRICTL_CMD=crictl
  local i id=
  for i in $(seq 1 30); do
    id=$(docker exec "$CRICTL_DOCKER" crictl ps --name "$POD" -q 2>/dev/null | head -1)
    [[ -n "$id" ]] && break
    sleep 2
  done
  [[ -n "$id" ]] || { log "no running container named $POD on $CRICTL_DOCKER"; return 1; }
  CRICTL_ID=$id
  RUNNER=crictl
  RUNG=1
  log "rung 1: crictl exec $CRICTL_ID in $CRICTL_DOCKER"
}
