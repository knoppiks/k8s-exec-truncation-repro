#!/usr/bin/env bash
# Rendering the payload pod. One manifest, optionally pinned to a node, so that
# "pod on the server node" and "pod on an agent node" are the same experiment
# with one variable moved.

# render_manifest [NODE_NAME]
#   Emits the manifest as JSON, with spec.nodeName set on the Pod if a node was
#   given. kubectl does the YAML→JSON conversion so the repository needs no yq.
render_manifest() {
  local node="${1:-}"
  if [[ -z "$node" ]]; then
    cat "$REPO_ROOT/manifests/payload-pod.yaml"
    return
  fi
  # --validate=false keeps the conversion offline: it is a YAML→JSON step, not
  # an admission check. The documents arrive as a stream, hence jq -s.
  kubectl create -f "$REPO_ROOT/manifests/payload-pod.yaml" \
    --dry-run=client --validate=false -o json |
    jq -s --arg n "$node" '{
      apiVersion: "v1",
      kind: "List",
      items: map(if .kind == "Pod" then .spec.nodeName = $n else . end)
    }'
}

# apply_payload NODE KUBECTL_ARGS...
#   Retried, because on a cluster that is seconds old the namespace exists
#   before its default ServiceAccount does, and the pod is rejected with
#   "error looking up service account". That is a startup race, not a result.
apply_payload() {
  local node="$1"
  shift
  local i
  for i in $(seq 1 30); do
    if render_manifest "$node" | kubectl "$@" apply -f - >&2; then
      return 0
    fi
    log "payload not accepted yet (attempt $i) — retrying"
    sleep 2
  done
  log "payload could not be created"
  return 1
}

# wait_pod_ready KUBECTL_ARGS...
wait_pod_ready() {
  kubectl "$@" -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=300s >&2
}
