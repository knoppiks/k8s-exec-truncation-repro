#!/usr/bin/env bash
# Minimal reproduction, as pasted into the upstream issue.
# Needs: kind, kubectl, docker, bash. Creates a two-node kind cluster "trunc".
set -u

cat <<'EOF' | kind create cluster --name trunc --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes: [{role: control-plane}, {role: worker}]
EOF
kubectl run payload --image=alpine:3.22 --restart=Never \
  --overrides='{"spec":{"nodeName":"trunc-worker"}}' -- sleep infinity
kubectl wait --for=condition=Ready pod/payload --timeout=120s

# The container writes exactly 32 MiB (33554432 bytes) and exits 0.
PAYLOAD='head -c 33554432 /dev/zero'

# A reader that consumes 1 MiB per second and prints how many bytes it got.
slow_count() {
  total=0
  while n=$(head -c 1048576 | wc -c) && [ "$n" -gt 0 ]; do
    total=$((total + n)); sleep 1
  done
  echo "got=$total"
}

# 1) kubectl exec through the apiserver: WebSocket (default), then SPDY.
for ws in true false; do
  echo -n "kubectl exec, websockets=$ws: "
  KUBECTL_REMOTE_COMMAND_WEBSOCKETS=$ws kubectl exec payload -- sh -c "$PAYLOAD" | slow_count
  echo "  kubectl exit code: ${PIPESTATUS[0]}"
done

# 2) The same reader on the node, reading crictl exec directly: only the CRI
#    streaming server is in the path. No kubelet, apiserver or network.
id=$(docker exec trunc-worker crictl ps --name payload -q)
echo -n "crictl exec on the node: "
docker exec trunc-worker bash -c "$(declare -f slow_count)
  crictl exec $id sh -c '$PAYLOAD' | slow_count
  echo \"  crictl exit code: \${PIPESTATUS[0]}\""

# Control: keep the process alive until the reader has caught up.
echo -n "kubectl exec, 'sleep 45' after the last write: "
kubectl exec payload -- sh -c "$PAYLOAD; sleep 45" | slow_count
