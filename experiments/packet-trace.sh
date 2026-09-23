#!/usr/bin/env bash
# Where on the path do the bytes stop, and how does each hop close?
#
# Every hop of an exec stream is a TCP connection, and TCP sequence numbers
# count bytes. Capturing headers on both kind nodes during a short read gives,
# per hop and per direction, how many bytes were sent and whether the sender
# closed gracefully (FIN) or aborted (RST). An RST discards whatever the
# sender's kernel still held for that connection; a FIN delivers it.
#
#   containerd --(lo, stream port)--> kubelet --(:10250)--> apiserver --(:6443)--> client
#
# For each hop the numbers answer one question: did everything that arrived at
# this component leave it again?
#
#   experiments/packet-trace.sh --size 32 --transports ws,spdy --attempts 4
#
# kind only. Captures run in helper containers that share the nodes' network
# namespaces, so nothing is installed into the nodes themselves.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT
export PATH="$REPO_ROOT/.tools:$PATH"

# shellcheck source=lib/report.sh
source "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/throttle.sh
source "$REPO_ROOT/lib/throttle.sh"
# shellcheck source=lib/run.sh
source "$REPO_ROOT/lib/run.sh"

SIZE=32
READER=slow
TRANSPORTS=ws,spdy
ATTEMPTS=4
DRAIN=0
OUTDIR=

while (($#)); do
  case "$1" in
    --size) SIZE=$2; shift 2 ;;
    --reader) READER=$2; shift 2 ;;
    --transports) TRANSPORTS=$2; shift 2 ;;
    --attempts) ATTEMPTS=$2; shift 2 ;;
    --drain) DRAIN=$2; shift 2 ;;
    --outdir) OUTDIR=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# shellcheck source=env/kind.sh
source "$REPO_ROOT/env/kind.sh"
: "${OUTDIR:=$REPO_ROOT/results/experiments/packet-trace}"
mkdir -p "$OUTDIR"

WORKER=$POD_NODE
CONTROL_PLANE=${KIND_CLUSTER}-control-plane
CAPTURE_IMAGE=${CAPTURE_IMAGE:-alpine:3.22}

stream_port() {
  docker exec "$WORKER" ss -ltnp |
    awk '/containerd/ && $4 ~ /^127\.0\.0\.1:/ { split($4, a, ":"); print a[2]; exit }'
}

gateway_ip() {
  docker network inspect kind \
    -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' |
    tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1
}

# start_capture NAME NODE FILTER — header-only capture in the node's netns.
start_capture() {
  local name="$1" node="$2" filter="$3"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --net "container:$node" \
    --cap-add NET_RAW --cap-add NET_ADMIN \
    -v "$CAPDIR:/cap" "$CAPTURE_IMAGE" sh -c "
      apk add --no-cache tcpdump >/dev/null 2>&1 || exit 90
      touch /cap/$name.ready
      exec tcpdump -i any -nn -s 128 -U -w /cap/$name.pcap '$filter'
    " >/dev/null
  local i
  for i in $(seq 1 60); do
    [[ -f "$CAPDIR/$name.ready" ]] && { sleep 1; return 0; }
    sleep 1
  done
  log "capture $name did not start"
  return 1
}

stop_capture() {
  docker stop -t 5 "$1" >/dev/null 2>&1 || true
  docker rm -f "$1" >/dev/null 2>&1 || true
}

# pcap_text NAME — the capture as text, absolute sequence numbers, epoch time.
# Rendered by the capture image so the host needs no tcpdump either.
pcap_text() {
  docker run --rm -v "$CAPDIR:/cap" "$CAPTURE_IMAGE" sh -c "
    apk add --no-cache tcpdump >/dev/null 2>&1 || exit 90
    tcpdump -r /cap/$1.pcap -nn -S -tt 2>/dev/null
  "
}

# flows — per direction of every connection: bytes carried, first FIN, first
# RST. Bytes are the span of sequence space after the SYN, modulo 2^32.
flows() {
  awk '
    {
      ip = 0
      for (i = 1; i <= NF; i++) if ($i == "IP") { ip = i; break }
      if (!ip) next
      t = $1; src = $(ip + 1); dst = $(ip + 3); sub(/:$/, "", dst)
      flags = $(ip + 5)
      key = src " > " dst
      seq = ""
      for (j = ip + 6; j <= NF; j++) if ($j == "seq") { seq = $(j + 1); sub(/,$/, "", seq); break }
      if (flags ~ /S/ && !(key in isn)) { split(seq, a, ":"); isn[key] = a[1] + 0 }
      if (seq != "" && (key in isn)) {
        n = split(seq, a, ":"); e = (n == 2 ? a[2] : a[1]) + 0
        d = e - isn[key]; if (d < 0) d += 4294967296
        if (d > span[key]) span[key] = d
      }
      if (flags ~ /F/ && !(key in fin)) fin[key] = t
      if (flags ~ /R/ && !(key in rst)) rst[key] = t
      if (!(key in first)) first[key] = t
    }
    END {
      for (k in span) {
        b = span[k] - 1
        if (k in fin) b -= 1
        printf "%s|%d|%s|%s|%s\n", k, (b < 0 ? 0 : b), first[k], \
          ((k in fin) ? fin[k] : "-"), ((k in rst) ? rst[k] : "-")
      }
    }
  '
}

# biggest FLOWS PATTERN — the direction matching PATTERN that carried most bytes.
biggest() {
  grep -E "$2" <<<"$1" | sort -t'|' -k2,2nr | head -1
}

field() { cut -d'|' -f"$2" <<<"$1"; }

# closer FLOWS SRC_PATTERN — how the side matching SRC_PATTERN closed: fin, rst
# or both, with the time of the first of them.
describe_close() {
  local line="$1" fin rst
  fin=$(field "$line" 4)
  rst=$(field "$line" 5)
  if [[ "$fin" != - && "$rst" != - ]]; then
    printf 'FIN@%s RST@%s' "$fin" "$rst"
  elif [[ "$rst" != - ]]; then
    printf 'RST@%s' "$rst"
  elif [[ "$fin" != - ]]; then
    printf 'FIN@%s' "$fin"
  else
    printf 'open'
  fi
}

CSV=$OUTDIR/hops.csv
[[ -f "$CSV" ]] || printf '%s\n' \
  'transport,attempt,drain,payload_bytes,client_got,client_exit,containerd_to_kubelet,kubelet_to_apiserver,apiserver_to_client,kubelet_close_to_containerd,containerd_close_to_kubelet,kubelet_close_to_apiserver,apiserver_close_to_kubelet,apiserver_close_to_client,verdict' \
  >"$CSV"

port=$(stream_port)
gw=$(gateway_ip)
[[ -n "$port" && -n "$gw" ]] || { log "could not find stream port ($port) or gateway ($gw)"; exit 1; }
log "containerd stream port on $WORKER: $port; client arrives from $gw"

expected=$((SIZE * 1024 * 1024))

for transport in ${TRANSPORTS//,/ }; do
  for attempt in $(seq 1 "$ATTEMPTS"); do
    tag="${transport}-drain${DRAIN}-attempt${attempt}"
    CAPDIR=$OUTDIR/$tag
    rm -rf "$CAPDIR"
    mkdir -p "$CAPDIR"
    chmod 777 "$CAPDIR"

    start_capture "cap-worker" "$WORKER" "tcp port 10250 or tcp port $port"
    start_capture "cap-cp" "$CONTROL_PLANE" "(tcp port 6443 and host $gw) or tcp port 10250"

    build_exec_argv "$(payload_cmd "$SIZE" "$DRAIN")"
    out=$(mktemp)
    set +e
    env "$(transport_env "$transport")" \
      timeout --signal=KILL $((120 + SIZE * 4 + DRAIN)) "${EXEC_ARGV[@]}" \
      2>"$CAPDIR/client.stderr" | sink "$READER" "$out"
    rc=${PIPESTATUS[0]}
    set -e
    got=$(stat -c %s "$out")
    rm -f "$out"

    sleep 3
    stop_capture cap-worker
    stop_capture cap-cp

    worker_flows=$(pcap_text cap-worker | flows)
    cp_flows=$(pcap_text cap-cp | flows)
    printf '%s\n' "$worker_flows" >"$CAPDIR/worker-flows.txt"
    printf '%s\n' "$cp_flows" >"$CAPDIR/control-plane-flows.txt"

    c2k=$(biggest "$worker_flows" "^127\.0\.0\.1\.$port > ")
    k2c=$(biggest "$worker_flows" " > 127\.0\.0\.1\.$port\|")
    k2a=$(biggest "$worker_flows" "\.10250 > ")
    a2k=$(biggest "$worker_flows" " > [0-9.]+\.10250\|")
    a2c=$(biggest "$cp_flows" "\.6443 > ")

    if ((got == expected)); then verdict=complete; else verdict=truncated; fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$transport" "$attempt" "$DRAIN" "$expected" "$got" "$rc" \
      "$(field "$c2k" 2)" "$(field "$k2a" 2)" "$(field "$a2c" 2)" \
      "$(describe_close "$k2c")" "$(describe_close "$c2k")" \
      "$(describe_close "$k2a")" "$(describe_close "$a2k")" \
      "$(describe_close "$a2c")" "$verdict" >>"$CSV"

    log "$(printf '%-4s #%s: client got %s of %s (exit %s) -> %s' \
      "$transport" "$attempt" "$got" "$expected" "$rc" "$verdict")"
    log "    containerd->kubelet   $(field "$c2k" 2) B, containerd $(describe_close "$c2k"), kubelet $(describe_close "$k2c")"
    log "    kubelet->apiserver    $(field "$k2a" 2) B, kubelet $(describe_close "$k2a"), apiserver $(describe_close "$a2k")"
    log "    apiserver->client     $(field "$a2c" 2) B, apiserver $(describe_close "$a2c")"
  done
done
