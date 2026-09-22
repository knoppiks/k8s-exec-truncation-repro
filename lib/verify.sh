#!/usr/bin/env bash
# Truth about the payload is produced where the payload is produced.
#
# A short read is a failure regardless of exit code: the far end of an exec
# stream cannot tell truncation from EOF, which is the whole defect. So the
# expected size and digest are computed by a second exec inside the same
# container, over the same path, whose own output is 80 bytes and therefore
# arrives intact even on a path that loses megabytes.

declare -A EXPECTED_SHA=()
declare -A EXPECTED_SIZE=()

# probe_expected SIZE_MIB — memoised; one tiny exec per size per environment.
probe_expected() {
  local size_mib="$1"
  [[ -n "${EXPECTED_SHA[$size_mib]:-}" ]] && return 0

  build_exec_argv "$(digest_cmd "$size_mib")"
  local sha
  sha=$(timeout --signal=KILL "${PROBE_TIMEOUT:-600}" "${EXEC_ARGV[@]}" 2>/dev/null | tr -d '[:space:]')

  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'in-container digest probe failed for %s MiB (got %q)\n' "$size_mib" "$sha" >&2
    return 1
  fi

  EXPECTED_SHA[$size_mib]=$sha
  EXPECTED_SIZE[$size_mib]=$((size_mib * 1024 * 1024))
}

expected_sha() {
  printf '%s\n' "${EXPECTED_SHA[$1]:-unprobed}"
}

# selfcheck_expected SIZE_MIB
#   The generator is deterministic, so the in-container digest must equal the
#   digest of the same bytes produced locally. If it does not, the harness is
#   measuring something other than what it thinks, and every later row is void.
selfcheck_expected() {
  local size_mib="$1" local_sha
  local_sha=$(dd if=/dev/zero bs=1048576 count="$size_mib" 2>/dev/null |
    tr '\0' 'x' | sha256sum | cut -d' ' -f1)
  [[ "$local_sha" == "${EXPECTED_SHA[$size_mib]}" ]]
}
