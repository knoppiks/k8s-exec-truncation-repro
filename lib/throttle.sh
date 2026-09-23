#!/usr/bin/env bash
# Rate-limited sink. coreutils only: no pv, no python.
#
# slow_sink BYTES_PER_SECOND OUTFILE
#   Reads stdin, writes OUTFILE, consuming at most BYTES_PER_SECOND per second.
#
# The point of the slow sink is to build a backlog along the exec path with a
# small payload. Loss tracks in-flight bytes, so a slow reader is a cheaper way
# to provoke the defect than a large payload.
#
# slow_sink is written in POSIX sh on purpose: it is also shipped verbatim into
# cluster nodes, to sit directly on crictl's stdout, and the k3s node image has
# only busybox. Both GNU and busybox dd report "<n> bytes ... copied".

slow_sink() {
  _rate="$1"
  _out="$2"
  : >"$_out"
  exec 3>>"$_out"
  while :; do
    # Data goes to fd 3, dd's own report stays on stdout so we can read the count.
    _n=$(dd iflag=fullblock bs="$_rate" count=1 2>&1 >&3 | awk '/bytes/ { print $1; exit }')
    _n=${_n:-0}
    [ "$_n" -eq 0 ] && break
    [ "$_n" -lt "$_rate" ] && break # short read with iflag=fullblock means EOF
    sleep 1
  done
  exec 3>&-
}

# fast_sink OUTFILE — the unthrottled control.
fast_sink() {
  cat >"$1"
}

# reader_rate READER — bytes per second for a reader profile, 0 for unthrottled.
reader_rate() {
  case "$1" in
    fast) printf '0\n' ;;
    slow) printf '%s\n' $((1024 * 1024)) ;;
    slow512k) printf '%s\n' $((512 * 1024)) ;;
    *)
      printf 'unknown reader: %s\n' "$1" >&2
      return 64
      ;;
  esac
}

# sink READER OUTFILE — dispatch on the reader name used in the CSV.
sink() {
  local rate
  rate=$(reader_rate "$1") || return 64
  if [[ "$rate" == 0 ]]; then
    fast_sink "$2"
  else
    slow_sink "$rate" "$2"
  fi
}

# slow_sink_source — the definition of slow_sink as text, for shipping into a
# node. Taken from this file rather than retyped, so that the reader measured in
# the node is the reader measured everywhere else.
slow_sink_source() {
  declare -f slow_sink
}
