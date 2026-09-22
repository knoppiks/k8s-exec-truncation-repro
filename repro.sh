#!/usr/bin/env bash
# k8s exec stdout truncation — one instrument, every environment.
#
#   ./repro.sh setup     --env k8s-a
#   ./repro.sh grid      --env k8s-a --sizes 8,32,128 --readers fast,slow
#   ./repro.sh report    --csv results/k8s-a/phase0.csv
#   ./repro.sh teardown  --env k8s-a
#
# Options: --sizes MiB,... --readers fast,slow --transports ws,spdy
#          --drains s,... --runs N --rung 1 --csv PATH --keep
#
# Requires: kubectl, docker, jq, coreutils, bash 4+. Nothing else. A maintainer
# asked to reproduce a bug will not install pv, python or a helm chart to do it.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export REPO_ROOT
# Tools fetched on demand live here and are never required to be installed
# system-wide. Today that is only kind, for the control group.
export PATH="$REPO_ROOT/.tools:$PATH"

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

ENV_FILE=k8s-a
SIZES=8,32,128
READERS=fast,slow
TRANSPORTS=ws,spdy
DRAINS=0,5
RUNS=3
CSV=
KEEP=0
RUNG_SELECT=

usage() {
  # The header comment is the help text; keeping them the same object means
  # they cannot disagree.
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
    "$REPO_ROOT/repro.sh"
  exit "${1:-0}"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --env) ENV_FILE=$2; shift 2 ;;
      --sizes) SIZES=$2; shift 2 ;;
      --readers) READERS=$2; shift 2 ;;
      --transports) TRANSPORTS=$2; shift 2 ;;
      --drains) DRAINS=$2; shift 2 ;;
      --runs) RUNS=$2; shift 2 ;;
      --csv) CSV=$2; shift 2 ;;
      --rung) RUNG_SELECT=$2; shift 2 ;;
      --keep) KEEP=1; shift ;;
      -h | --help) usage 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; usage 64 ;;
    esac
  done
}

load_env() {
  local f="$REPO_ROOT/env/$ENV_FILE.sh"
  [[ -f "$f" ]] || { printf 'no such env: %s\n' "$f" >&2; exit 66; }
  # shellcheck source=/dev/null
  source "$f"
  : "${CSV:=$REPO_ROOT/results/$ENV_NAME/runs.csv}"
}

cmd_setup() {
  load_env
  env_up
  local delay=${NETEM_DELAY_MS:-0}
  if [[ -n "${NETEM_NETWORK:-}" && "$delay" != 0 ]]; then
    netem_apply "$NETEM_NETWORK" "$delay" || true
  fi
  log "env up: $(env_describe)"
}

cmd_teardown() {
  load_env
  [[ -n "${NETEM_NETWORK:-}" ]] && netem_clear "$NETEM_NETWORK"
  env_down
  log "env down: $ENV_NAME"
}

cmd_probe() {
  load_env
  local size=${SIZES%%,*}
  probe_expected "$size"
  log "in-container digest for ${size} MiB: $(expected_sha "$size")"
  if selfcheck_expected "$size"; then
    log "selfcheck ok: generator is deterministic and reproducible locally"
  else
    log "SELFCHECK FAILED: in-container digest != local digest. Harness is void."
    exit 1
  fi
}

cmd_grid() {
  load_env
  # --rung 1 drops to containerd's streaming server on the node that hosts the
  # pod: no kubelet, no apiserver, no tunnel, no LAN. Everything else in the
  # cell is unchanged, which is the point.
  if [[ "$RUNG_SELECT" == 1 ]]; then
    use_crictl
    TRANSPORTS=na
  fi
  local outdir="$REPO_ROOT/results/$ENV_NAME/artifacts"
  log "env: $(env_describe)"
  log "csv: $CSV"
  run_grid "$CSV" "$outdir"
  ((KEEP)) || rmdir "$outdir" 2>/dev/null || true
  summarise "$CSV"
}

cmd_report() {
  [[ -n "$CSV" ]] || { printf 'need --csv\n' >&2; exit 64; }
  summarise "$CSV"
}

main() {
  local sub=${1:-}
  (($#)) && shift || true
  parse_args "$@"
  case "$sub" in
    setup) cmd_setup ;;
    teardown) cmd_teardown ;;
    probe) cmd_probe ;;
    grid) cmd_grid ;;
    report) cmd_report ;;
    "" | -h | --help) usage 0 ;;
    *) printf 'unknown subcommand: %s\n' "$sub" >&2; usage 64 ;;
  esac
}

main "$@"
