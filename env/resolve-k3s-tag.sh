#!/usr/bin/env bash
# resolve-k3s-tag.sh 1.30  ->  v1.30.14-k3s1
#
# The matrix is written in minor versions because that is what the question is
# about ("did the 1.30 WebSocket default fix this?"), while the image needs an
# exact tag. Resolved at run time rather than pinned by hand so the file does
# not rot, and printed into the results so any row can be reproduced exactly.

set -euo pipefail

minor=${1:?usage: resolve-k3s-tag.sh <minor, e.g. 1.30>}

page=1
best=
while ((page <= 10)); do
  body=$(curl -fsSL "https://hub.docker.com/v2/repositories/rancher/k3s/tags?page_size=100&page=${page}&name=v${minor}.")
  mapfile -t tags < <(printf '%s' "$body" |
    jq -r '.results[].name | select(test("^v[0-9.]+-k3s[0-9]+$"))')
  for t in "${tags[@]}"; do
    [[ "$t" == v${minor}.* ]] || continue
    if [[ -z "$best" ]]; then
      best=$t
    elif [[ "$(printf '%s\n%s\n' "$best" "$t" | sort -V | tail -1)" == "$t" ]]; then
      best=$t
    fi
  done
  printf '%s' "$body" | jq -e '.next != null' >/dev/null 2>&1 || break
  ((page++))
done

[[ -n "$best" ]] || { printf 'no k3s tag found for minor %s\n' "$minor" >&2; exit 1; }
printf '%s\n' "$best"
