#!/usr/bin/env bash
# Rung 2 — straight at kubelet:10250, no apiserver, no tunnel.
#
# Not implemented, deliberately, and only reachable if rung 4 truncates.
#
# kubelet's /exec endpoint is not the Kubernetes API's. It upgrades to
# SPDY/3.1, which no shell tool speaks: curl cannot frame it, kubectl cannot
# address it (it builds /api/v1/namespaces/.../exec paths, kubelet serves
# /exec/{ns}/{pod}/{container}), and a hand-rolled client means zlib with
# SPDY's fixed header dictionary. That is a program, not a probe, and this
# repository's constraint is that it runs with kubectl, docker and coreutils.
#
# It is also not needed for the decision it was planned for. If rung 4
# truncates, the tunnel and the distribution are both eliminated and the defect
# is in vanilla Kubernetes; splitting kubelet from apiserver narrows the fix but
# not the filing. Say so in the issue and let the maintainers, who have the
# tooling, split it.
#
# If it does become necessary: run a kubelet-side capture instead of a client.
#   docker exec <node> sh -c 'cat /proc/net/tcp' is not enough; use
#   `crictl exec` (rung 1) to establish what containerd hands up, and compare
#   byte counts in kubelet's own logs at -v=6.

printf 'rung 2 is not implemented: see the comment in %s\n' "${BASH_SOURCE[0]}" >&2
exit 3
