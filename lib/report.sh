#!/usr/bin/env bash
# One CSV row per run, one markdown table per report. Same shape everywhere, so
# production numbers and clean-room numbers can be set side by side.

CSV_HEADER='env,rung,transport,size_mib,reader,drain,expected_bytes,got_bytes,lost_bytes,sha_match,exit_code,stderr_len,seconds,verdict'

csv_init() {
  local csv="$1"
  mkdir -p "$(dirname "$csv")"
  [[ -f "$csv" ]] || printf '%s\n' "$CSV_HEADER" >"$csv"
}

# csv_append CSV ENV RUNG TRANSPORT SIZE READER DRAIN
#   Reads the RUN_* globals left behind by run_once.
csv_append() {
  local csv="$1" envname="$2" rung="$3" transport="$4" size="$5" reader="$6" drain="$7"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$envname" "$rung" "$transport" "$size" "$reader" "$drain" \
    "$RUN_EXPECTED_BYTES" "$RUN_GOT_BYTES" "$((RUN_EXPECTED_BYTES - RUN_GOT_BYTES))" \
    "$RUN_SHA_MATCH" "$RUN_EXIT" "$RUN_STDERR_LEN" "$RUN_SECONDS" "$RUN_VERDICT" \
    >>"$csv"
}

# summarise CSV — cells aggregated over repeats, cheapest failure first.
summarise() {
  local csv="$1"
  awk -F, '
    NR == 1 { next }
    {
      key = $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6
      runs[key]++
      if ($14 != "complete") { bad[key]++ }
      lost[key] += $9
      if ($9 > worst[key]) { worst[key] = $9 }
      bytes[key] = $7
    }
    END {
      printf "| env | rung | transport | size MiB | reader | drain | failed/runs | worst loss | mean loss |\n"
      printf "|---|---|---|---|---|---|---|---|---|\n"
      for (k in runs) {
        split(k, f, "|")
        printf "| %s | %s | %s | %s | %s | %s | %d/%d | %d | %d |\n",
          f[1], f[2], f[3], f[4], f[5], f[6], bad[k] + 0, runs[k],
          worst[k] + 0, lost[k] / runs[k]
      }
    }
  ' "$csv" | { read -r h1; read -r h2; printf '%s\n%s\n' "$h1" "$h2"; sort -t'|' -k5,5n -k8,8 ; }
}

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}
