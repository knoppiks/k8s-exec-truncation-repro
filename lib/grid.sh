#!/usr/bin/env bash
# The cell loop. Every rung of the ladder and every environment runs this exact
# function, so any two rows in any two CSVs are comparable without caveat.
#
# Reads the globals SIZES READERS TRANSPORTS DRAINS RUNS ENV_NAME RUNG.

split() { printf '%s\n' "${1//,/ }"; }

# Slow readers are the long pole: 1 MiB/s plus slack, floor of two minutes.
timeout_for() {
  local size="$1" reader="$2"
  case "$reader" in
    fast) printf '%s\n' $((120 + size * 2)) ;;
    *) printf '%s\n' $((120 + size * 4)) ;;
  esac
}

# run_grid CSV OUTDIR
run_grid() {
  local csv="$1" outdir="$2"
  csv_init "$csv"
  mkdir -p "$outdir"

  local size reader transport drain run tag
  for size in $(split "$SIZES"); do
    probe_expected "$size"
    selfcheck_expected "$size" ||
      { log "SELFCHECK FAILED for ${size} MiB — harness is void, aborting"; return 1; }
    for reader in $(split "$READERS"); do
      for transport in $(split "$TRANSPORTS"); do
        for drain in $(split "$DRAINS"); do
          for run in $(seq 1 "$RUNS"); do
            tag="${ENV_NAME}-r${RUNG}-${transport}-${size}mib-${reader}-drain${drain}-run${run}"
            RUN_TIMEOUT=$(timeout_for "$size" "$reader")
            run_once "$size" "$reader" "$transport" "$drain" "$outdir" "$tag"
            csv_append "$csv" "$ENV_NAME" "$RUNG" "$transport" "$size" "$reader" "$drain"
            log "$(printf '%-12s rung%-2s %4s MiB %-4s %-4s drain=%-2s run=%s -> %-9s lost=%s in %ss' \
              "$ENV_NAME" "$RUNG" "$size" "$reader" "$transport" "$drain" "$run" \
              "$RUN_VERDICT" "$((RUN_EXPECTED_BYTES - RUN_GOT_BYTES))" "$RUN_SECONDS")"
          done
        done
      done
    done
  done
}

# failures_in CSV RUNG — how many non-complete rows that rung produced.
failures_in() {
  awk -F, -v rung="$2" 'NR > 1 && $2 == rung && $14 != "complete" { n++ } END { print n + 0 }' "$1"
}

# runs_in CSV RUNG
runs_in() {
  awk -F, -v rung="$2" 'NR > 1 && $2 == rung { n++ } END { print n + 0 }' "$1"
}
