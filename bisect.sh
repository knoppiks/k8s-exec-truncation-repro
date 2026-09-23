#!/usr/bin/env bash
# Phase 1 — which layer loses the bytes.
#
# A ladder, not a sequence. Each rung adds exactly one component to the path,
# and every rung runs the identical generator and the identical verification as
# the production calibration, so the rows compare directly.
#
#   rung 0  sha256sum inside the pod          no stream at all
#   rung 1  k3s crictl exec on the node       containerd streaming server alone
#   rung 2  https://node:10250/exec           + kubelet CRI proxy   (conditional)
#   rung 3  apiserver, egress-selector=agent  + apiserver + remotedialer
#   rung 4  apiserver, egress-selector=disabled  rung 3 minus remotedialer
#
# Branching:
#   rung 1 truncates                  -> containerd. Stop.
#   rung 3 truncates, rung 4 clean    -> the k3s tunnel. Stop.
#   rung 4 truncates too              -> kubelet or apiserver; rung 2 splits them.
#   nothing truncates                 -> the clean room does not reproduce it.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REPO_ROOT

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/throttle.sh
source "$REPO_ROOT/lib/throttle.sh"
# shellcheck source=lib/run.sh
source "$REPO_ROOT/lib/run.sh"
# shellcheck source=lib/verify.sh
source "$REPO_ROOT/lib/verify.sh"
# shellcheck source=lib/grid.sh
source "$REPO_ROOT/lib/grid.sh"
# shellcheck source=lib/netem.sh
source "$REPO_ROOT/lib/netem.sh"

# Defaults are the Phase 0 baseline; override on the command line.
SIZES=${SIZES:-128}
READERS=${READERS:-slow}
TRANSPORTS=${TRANSPORTS:-ws,spdy}
DRAINS=${DRAINS:-0}
RUNS=${RUNS:-5}
POD_NODE=${POD_NODE:-agent}
K3S_VERSION=${K3S_VERSION:-v1.36.4-k3s1}
CSV=${CSV:-$REPO_ROOT/results/bisect/ladder.csv}
OUTDIR=$REPO_ROOT/results/bisect/artifacts
KEEP_CLUSTER=${KEEP_CLUSTER:-0}

while (($#)); do
  case "$1" in
    --sizes) SIZES=$2; shift 2 ;;
    --readers) READERS=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --drains) DRAINS=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --pod-node) POD_NODE=$2; shift 2 ;;
    --k3s-version) K3S_VERSION=$2; shift 2 ;;
    --csv) CSV=$2; shift 2 ;;
    --keep-cluster) KEEP_CLUSTER=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

export POD_NODE K3S_VERSION

VERDICT_FILE=$REPO_ROOT/results/bisect/verdict.md
mkdir -p "$(dirname "$CSV")" "$OUTDIR"

# ------------------------------------------------------------------ rungs ----

bring_up() {
  local egress="$1"
  EGRESS=$egress
  export EGRESS
  # shellcheck source=env/k3s-docker.sh
  source "$REPO_ROOT/env/k3s-docker.sh"
  ENV_NAME="k3s-docker-${K3S_VERSION}-egress-${egress}"
  env_down
  env_up
  # Backlog forcing, where the host allows it. A rung that passes only because
  # the host was fast has eliminated nothing.
  if [[ "${NETEM_DELAY_MS:-0}" != 0 ]]; then
    netem_apply "$NETEM_NETWORK" "$NETEM_DELAY_MS" || true
  fi
  log "cluster up: $(env_describe)"
}

# Rung 0 — the payload never crosses a stream boundary. If this fails, nothing
# below it means anything.
rung0() {
  RUNG=0
  RUNNER=kubectl
  local size
  for size in $(split "$SIZES"); do
    unset "EXPECTED_SHA[$size]"
    probe_expected "$size"
    if selfcheck_expected "$size"; then
      RUN_EXPECTED_BYTES=$((size * 1024 * 1024))
      RUN_GOT_BYTES=$RUN_EXPECTED_BYTES
      RUN_SHA_MATCH=yes RUN_EXIT=0 RUN_STDERR_LEN=0 RUN_SECONDS=0 RUN_VERDICT=complete
    else
      RUN_EXPECTED_BYTES=$((size * 1024 * 1024))
      RUN_GOT_BYTES=0
      RUN_SHA_MATCH=no RUN_EXIT=0 RUN_STDERR_LEN=0 RUN_SECONDS=0 RUN_VERDICT=corrupt
    fi
    csv_append "$CSV" "$ENV_NAME" 0 na "$size" inpod 0
    log "rung 0: ${size} MiB hashed in-pod -> $RUN_VERDICT"
  done
}

# The control for rung 1: docker's own hijacked stream, no CRI behind it.
rung_docker() {
  RUNG=0.5
  RUNNER=dockerexec
  DOCKER_EXEC_TARGET=$(node_container "$POD_NODE")
  export DOCKER_EXEC_TARGET
  local saved=$TRANSPORTS
  TRANSPORTS=na
  run_grid "$CSV" "$OUTDIR"
  TRANSPORTS=$saved
  RUNNER=kubectl
}

rung1() {
  use_crictl || return 1
  local saved_transports=$TRANSPORTS
  TRANSPORTS=na
  run_grid "$CSV" "$OUTDIR"
  TRANSPORTS=$saved_transports
  RUNNER=kubectl
}

rung_apiserver() {
  RUNG=$1
  RUNNER=kubectl
  run_grid "$CSV" "$OUTDIR"
}

verdict() {
  printf '%s\n' "$1" | tee "$VERDICT_FILE" >&2
}

# ------------------------------------------------------------------- main ----

log "bisect: sizes=$SIZES readers=$READERS transports=$TRANSPORTS drains=$DRAINS runs=$RUNS pod_node=$POD_NODE"
csv_init "$CSV"

bring_up agent

rung0
rung_docker
rung1 || log "rung 1 unavailable — containerd is not eliminated, read the verdict accordingly"
rung_apiserver 3

r05_fail=$(failures_in "$CSV" 0.5)
r1_fail=$(failures_in "$CSV" 1)
r3_fail=$(failures_in "$CSV" 3)
log "failures — rung 0.5: $r05_fail/$(runs_in "$CSV" 0.5), rung 1: $r1_fail/$(runs_in "$CSV" 1), rung 3: $r3_fail/$(runs_in "$CSV" 3)"

if ((r05_fail > 0)); then
  verdict "inconclusive at the bottom of the ladder: docker exec alone truncates ($r05_fail failures at rung 0.5), so rung 1 cannot be read as a statement about containerd. Re-run rung 1 with a reader that does not cross docker's hijacked stream before concluding anything about the runtime."
elif ((r1_fail > 0)); then
  verdict "containerd: the streaming server truncates with no kubelet, apiserver or tunnel in the path (rung 1 failed $r1_fail times, while docker exec alone was clean $(runs_in "$CSV" 0.5) times). File against containerd/containerd, beside #13934."
else
  # Rung 4 is worth running whatever rung 3 did: if rung 3 was clean, rung 4
  # documents that removing the tunnel did not change a negative either.
  bring_up disabled
  rung_apiserver 4
  r4_fail=$(failures_in "$CSV" 4)
  log "rung 4 failures: $r4_fail/$(runs_in "$CSV" 4)"

  if ((r3_fail > 0 && r4_fail == 0)); then
    verdict "k3s: truncation appears with egress-selector-mode=agent and disappears with it disabled (rung 3 failed $r3_fail, rung 4 failed 0). File against k3s-io/k3s; no such issue exists today. Rung 2 is unnecessary."
  elif ((r4_fail > 0)); then
    verdict "kubernetes: truncation survives removal of the k3s tunnel (rung 4 failed $r4_fail). The defect is in kubelet or apiserver. Rung 2 (direct kubelet:10250) is now worth its cost and splits the two. Reopen kubernetes/kubernetes#60140 with this reproduction."
  else
    verdict "clean room green: no rung truncated locally. This is a real outcome, not a formality — the k8s-a numbers stand, and the difference between the two environments is now the object of study. Do not file upstream on this evidence."
  fi
fi

((KEEP_CLUSTER)) || env_down
summarise "$CSV"
