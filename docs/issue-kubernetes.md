# Draft — kubernetes/kubernetes

Not filed. Retarget or discard once the matrix in `results/matrix/` is complete.
The bisection in `results/bisect/` selected this target: see `results/bisect/verdict.md`.

---

**Title:** `kubectl exec` silently truncates stdout when the client reads slower than the container writes

### What happened

A process in a container writes N bytes to stdout and exits. `kubectl exec` delivers
fewer than N bytes. In most cases it exits `0` and prints nothing on stderr, so the short
read is indistinguishable from a complete one.

Reproduced on a two-node **kind** cluster (v1.37.0, containerd 2.3.4) with no proxy, no
service mesh and no distribution-specific components:

| transport | runs | truncated | worst loss of 32 MiB | exit 0 and silent |
|---|---|---|---|---|
| `v5.channel.k8s.io` (default) | 5 | 4 | 2 871 296 B | 2 of 4 |
| SPDY (`KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false`) | 5 | 5 | 3 271 680 B | 5 of 5 |

The trigger is not payload size but **bytes in flight**: a consumer that reads at
1 MiB/s truncates a 32 MiB stream, while the same 32 MiB read at line rate arrives
intact. This is why the failure looks size-dependent in the older reports — a bigger
payload is just another way to build a backlog.

### What I expected

Either all N bytes, or a non-zero exit with an error. Silent partial delivery on a
stream whose length the receiver cannot know is the dangerous outcome: it corrupts
backups taken with `kubectl exec ... > archive.tar` and reports success.

### How to reproduce

```
git clone https://github.com/knoppiks/k8s-exec-truncation-repro
cd k8s-exec-truncation-repro
./repro.sh setup --env kind
./repro.sh grid --env kind --sizes 32 --readers slow --transports ws,spdy --drains 0 --runs 5
```

`--readers slow` is a `dd`+`sleep` loop consuming 1 MiB/s; nothing beyond `kubectl`,
`docker` and coreutils is required. The payload is `dd if=/dev/zero | tr '\0' 'x'`, so the
expected digest is a constant, and the expected size and digest are additionally computed
by a second exec **inside the container**, whose own output is 80 bytes.

### Where it is not

A ladder was run with the identical generator and verification at each rung
(`results/bisect/ladder-1.36.4-agent.csv`, 32 MiB, 1 MiB/s reader, 5 runs per cell):

| rung | path | truncated |
|---|---|---|
| 0 | `sha256sum` inside the pod | 0/1 |
| 0.5 | `docker exec` into the node container | 0/5 |
| 1 | `crictl exec` on the node — containerd's streaming server | 0/5 |
| 3 | `kubectl exec` via apiserver, k3s `egress-selector-mode=agent` | 6/10 |
| 4 | `kubectl exec` via apiserver, k3s `egress-selector-mode=disabled` | 9/10 |

containerd delivers all 32 MiB to a 1 MiB/s reader every time. The same container, the
same payload and the same reader lose bytes as soon as the apiserver is in the path, and
they keep losing them when the distribution's proxying tunnel is removed. kind, which has
no such tunnel at all, loses them too.

### Which releases

Same cell, five runs per transport, one cluster per release (`results/matrix/`):

| release | WebSocket truncated | SPDY truncated | silent failures |
|---|---|---|---|
| kind v1.30.13 | 4/5 | 5/5 | 9 |
| kind v1.32.11 | 5/5 | 4/5 | 7 |
| kind v1.34.11 | 4/5 | 3/5 | 6 |
| kind v1.37.0 | 4/5 | 5/5 | 7 |
| k3s v1.30.14-k3s2 | 5/5 | 2/5 | 3 |
| k3s v1.32.13-k3s1 | 5/5 | 0/5 | 2 |
| k3s v1.34.11-k3s1 | 5/5 | 0/5 | 1 |
| k3s v1.36.4-k3s1 | 5/5 | 2/5 | 2 |

58 of 80 runs truncated; 37 of those exited `0` with an empty stderr. 1.30 — the release
that made WebSocket the default, and the reason #124571 was redirected to #60140 — is not
better than 1.37.

### Environment

- kind v0.33.0, node image `kindest/node:v1.37.0`, containerd 2.3.4, two nodes, pod on the worker
- client `kubectl` v1.36.4 and v1.37.x, same result
- also reproduced on k3s v1.36.4+k3s1 in docker, and on a three-node k3s cluster over a LAN

### Relation to existing issues

- **#60140** (`kubectl cp` fails on large files) was closed 2025-07-12 for want of a
  reproduction. This is one, on current releases, with the loss quantified in bytes.
- **#124571** was closed as stale and redirected to #60140 on the grounds that the 1.30
  WebSocket default fixed it. The WebSocket path truncates here as well.
- **containerd#13934** is the stdin analogue. This is stdout, and rung 1 above says
  containerd is not the layer that loses it.

### Notes for whoever picks this up

The workaround that cures it completely is keeping the process alive after its last write
— but the delay has to exceed the consumer's remaining backlog, not a fixed five seconds.
Against a 1 MiB/s reader and 32 MiB, `sleep 5` left the loss essentially unchanged (4/6
runs truncated, against 5/6 with no delay at all), while `sleep 45` — longer than the
32 seconds the consumer still needed — was clean 6/6. That is consistent with teardown on
process exit discarding whatever has not yet been
written to the client, rather than with a lost or reordered frame.
