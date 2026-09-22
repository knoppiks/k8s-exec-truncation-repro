#!/usr/bin/env bash
# Sweep versions locally, the same way CI sweeps them.
#
#   ./matrix.sh k3s  1.30 1.32 1.34 1.36
#   ./matrix.sh kind v1.30.13 v1.33.4
#
# One cluster per version, built and destroyed in turn, because the question is
# whether a given release loses bytes and not how several of them interact.
#
# The cell is the Phase 0 baseline unless overridden by the environment:
#   SIZES READERS TRANSPORTS DRAINS RUNS

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=env/baseline.sh
source "$REPO_ROOT/env/baseline.sh"

SIZES=${SIZES:-$BASELINE_SIZES}
READERS=${READERS:-$BASELINE_READERS}
TRANSPORTS=${TRANSPORTS:-$BASELINE_TRANSPORTS}
DRAINS=${DRAINS:-$BASELINE_DRAINS}
RUNS=${RUNS:-$BASELINE_RUNS}

# collate DIR — merge the per-version CSVs into all.csv, taking the version
# from the file name so that one table can hold every release. Rows written
# before ENV_NAME carried the version are corrected here rather than re-run.
collate() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name '*.csv' ! -name all.csv -print0 |
    sort -z |
    xargs -0 awk -F, -v OFS=, '
      FNR == 1 {
        name = FILENAME
        sub(/.*\//, "", name)
        sub(/\.csv$/, "", name)
        if (!header++) print
        next
      }
      { $1 = name; print }
    ' >"$dir/all.csv"
}

flavour=${1:?usage: matrix.sh <k3s|kind> <version>...}
shift
versions=("$@")
((${#versions[@]})) || { printf 'no versions given\n' >&2; exit 64; }

for v in "${versions[@]}"; do
  case "$flavour" in
    k3s)
      tag=$v
      [[ "$tag" == v* ]] || tag=$("$REPO_ROOT/env/resolve-k3s-tag.sh" "$v")
      printf '\n=== k3s %s ===\n' "$tag" >&2
      export K3S_VERSION=$tag ENV_NAME="k3s-$tag"
      "$REPO_ROOT/repro.sh" teardown --env k3s-docker || true
      "$REPO_ROOT/repro.sh" setup --env k3s-docker
      "$REPO_ROOT/repro.sh" grid --env k3s-docker \
        --sizes "$SIZES" --readers "$READERS" --transports "$TRANSPORTS" \
        --drains "$DRAINS" --runs "$RUNS" --keep \
        --csv "$REPO_ROOT/results/matrix/k3s-${tag}.csv"
      "$REPO_ROOT/repro.sh" teardown --env k3s-docker || true
      ;;
    kind)
      printf '\n=== kind node %s ===\n' "$v" >&2
      export KIND_NODE_IMAGE="kindest/node:$v" ENV_NAME="kind-$v"
      "$REPO_ROOT/repro.sh" teardown --env kind || true
      "$REPO_ROOT/repro.sh" setup --env kind
      "$REPO_ROOT/repro.sh" grid --env kind \
        --sizes "$SIZES" --readers "$READERS" --transports "$TRANSPORTS" \
        --drains "$DRAINS" --runs "$RUNS" --keep \
        --csv "$REPO_ROOT/results/matrix/kind-${v}.csv"
      "$REPO_ROOT/repro.sh" teardown --env kind || true
      ;;
    *)
      printf 'unknown flavour: %s\n' "$flavour" >&2
      exit 64
      ;;
  esac
done

printf '\n=== all versions ===\n' >&2
collate "$REPO_ROOT/results/matrix"
"$REPO_ROOT/repro.sh" report --csv "$REPO_ROOT/results/matrix/all.csv"
