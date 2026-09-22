#!/usr/bin/env bash
# Rate-limited sink. coreutils only: no pv, no python.
#
# slow_sink BYTES_PER_SECOND OUTFILE
#   Reads stdin, writes OUTFILE, consuming at most BYTES_PER_SECOND per second.
#
# The point of the slow sink is to build a backlog along the exec path with a
# small payload. Loss tracks in-flight bytes, so a slow reader is a cheaper way
# to provoke the defect than a large payload.

slow_sink() {
  local rate="$1" out="$2"
  local err n

  : >"$out"
  exec 3>>"$out"
  while :; do
    # Data goes to fd 3, dd's own report stays on stdout so we can read the count.
    err=$(dd iflag=fullblock bs="$rate" count=1 2>&1 >&3)
    n=$(printf '%s\n' "$err" | awk '/bytes/ {print $1; exit}')
    n=${n:-0}
    (( n == 0 )) && break
    (( n < rate )) && break # short read with iflag=fullblock means EOF
    sleep 1
  done
  exec 3>&-
}

# fast_sink OUTFILE — the unthrottled control.
fast_sink() {
  cat >"$1"
}

# sink READER OUTFILE — dispatch on the reader name used in the CSV.
sink() {
  local reader="$1" out="$2"
  case "$reader" in
    fast) fast_sink "$out" ;;
    slow) slow_sink "$((1024 * 1024))" "$out" ;;
    slow512k) slow_sink "$((512 * 1024))" "$out" ;;
    *)
      printf 'unknown reader: %s\n' "$reader" >&2
      return 64
      ;;
  esac
}
