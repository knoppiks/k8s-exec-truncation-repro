#!/usr/bin/env bash
# Backlog forcing for hosts that are too fast to fail.
#
# A single machine with client, apiserver, kubelet and containerd on one kernel
# drains the stream as fast as it is produced, which is precisely the
# configuration that never loses bytes. Delay on the docker bridge puts bytes
# in flight again.
#
# Requires passwordless sudo, which GitHub runners have and a workstation
# usually does not. Every function is a no-op without it, and says so, because
# a silently skipped mitigation turns a green matrix into a false negative.

netem_iface() {
  local net="${1:-k3s-repro}" id
  id=$(docker network inspect "$net" -f '{{.Id}}' 2>/dev/null) || return 1
  printf 'br-%s\n' "${id:0:12}"
}

netem_available() {
  sudo -n true 2>/dev/null && command -v tc >/dev/null 2>&1
}

# netem_apply NETWORK DELAY_MS
netem_apply() {
  local net="$1" delay="${2:-20}"
  if ! netem_available; then
    log "netem: unavailable (needs passwordless sudo and tc) — backlog forcing OFF"
    return 1
  fi
  local iface
  iface=$(netem_iface "$net") || { log "netem: no bridge for network $net"; return 1; }
  sudo tc qdisc replace dev "$iface" root netem delay "${delay}ms"
  log "netem: ${delay}ms delay on $iface"
}

netem_clear() {
  local net="$1" iface
  netem_available || return 0
  iface=$(netem_iface "$net") || return 0
  sudo tc qdisc del dev "$iface" root 2>/dev/null || true
  log "netem: cleared on $iface"
}
