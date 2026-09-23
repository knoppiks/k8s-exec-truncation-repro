# `kubectl exec` truncates stdout, and it is not the distribution's fault

A process in a container writes N bytes and exits. `kubectl exec` hands you fewer than N.
Usually it exits `0` and prints nothing, so a short result is indistinguishable from a
complete one.

This repository is the reproduction that
[kubernetes/kubernetes#60140](https://github.com/kubernetes/kubernetes/issues/60140) was
closed for wanting. It is a diagnostic instrument, not a fix: nothing here ships to a
cluster.

**The trigger is bytes in flight, not payload size.** A consumer reading at 1 MiB/s loses
megabytes out of a 32 MiB stream; the same 32 MiB read at line rate arrives intact. Large
payloads are simply another way of building a backlog, which is why every earlier report
of this describes it as a size problem.

---

## What it cost before it was measured

A 29 MB Minecraft world archive arrived as 16 MB, cut inside a region file, and the backup
was recorded as successful. `kubectl` had exited `0`.

## The claim, in one table

32 MiB of deterministic payload, drained at 1 MiB/s, no drain delay, five runs per cell.
Same generator, same verification, every row.

| Where | What is in the path | Truncated |
|---|---|---|
| in-pod `sha256sum` | nothing | 0/1 |
| `docker exec` into the node container | docker's hijacked stream | 0/5 |
| `crictl exec` on the node | + containerd's streaming server | **0/5** |
| `kubectl exec`, k3s in docker, tunnel on | + kubelet + apiserver + k3s remotedialer | 6/10 |
| `kubectl exec`, k3s in docker, tunnel off | + kubelet + apiserver | 9/10 |
| `kubectl exec`, **kind**, vanilla Kubernetes 1.37 | + kubelet + apiserver | **9/10** |
| `kubectl exec`, three-node k3s over a LAN | + the LAN | 5/6 at this cell |

containerd delivers all 32 MiB to a slow reader every time. The bytes go missing once the
apiserver is in the path, and they keep going missing when the distribution, its tunnel,
the LAN and docker are all removed one at a time.

**It is upstream Kubernetes.** Not k3s, not containerd, not the network.

## The evidence

### Phase 0 — calibration against a production cluster

k3s v1.36.4+k3s1, three servers, embedded etcd, flannel `wireguard-native`,
`egress-selector-mode` unset (therefore `agent`), client on the LAN. 72 runs, 25 failures
(`results/k8s-a/phase0.csv`).

| size | reader | transport | drain | failed/runs | worst loss |
|---|---|---|---|---|---|
| 8 MiB | 1 MiB/s | SPDY | 0 s | 1/3 | 388 096 B |
| 8 MiB | 1 MiB/s | WebSocket | 0 s | 0/3 | — |
| 32 MiB | 1 MiB/s | **WebSocket** | 0 s | **3/3** | 8 132 608 B |
| 32 MiB | 1 MiB/s | SPDY | 0 s | 2/3 | 6 209 536 B |
| 32 MiB | line rate | either | 0 s | 0/6 | — |
| 128 MiB | line rate | SPDY | 0 s | 3/3 | 8 858 624 B |
| 128 MiB | line rate | WebSocket | 0 s | 0/3 | — |
| 128 MiB | 1 MiB/s | either | 0 s | 6/6 | 8 851 456 B |

The cheapest cell that fails reliably — **32 MiB at 1 MiB/s over WebSocket, 3/3** — is the
baseline for everything after it (`env/baseline.sh`). It costs 32 seconds and 32 MiB per
run, against the 160 MB that happened to be tried first.

**Silence.** On this cluster every SPDY failure was silent: exit `0`, empty stderr, 13 of
13. Every WebSocket failure was loud: exit `1` and
`websocket: close 1006 (abnormal closure): unexpected EOF`, or
`read: connection reset by peer`, 12 of 12. In the clean room the WebSocket failures are
silent too, so the split is not a property of the transport — it is a property of how far
the teardown gets before the client notices.

### The workaround, and why its usual form is wrong

Keeping the process alive after its last write is the known cure. It is a race, not a
fix, and the margin has to cover the consumer's remaining backlog:

| drain after last write | 32 MiB at 1 MiB/s | WebSocket | SPDY |
|---|---|---|---|
| none | 32 s of backlog | 3/3 truncated | 2/3 truncated |
| `sleep 5` | 27 s still queued at exit | 3/3 truncated | 1/3 truncated |
| `sleep 45` | backlog drained before exit | 0/3 | 0/3 |

`sleep 5` is the number that circulates. Against a slow consumer it buys nothing.

### Phase 1 — the ladder

`bisect.sh` climbs one component at a time, on a throwaway k3s in plain docker (one
server, one agent, exact version pinning, nothing else installed). Results in
`results/bisect/`, verdict in `results/bisect/verdict.md`.

Rung 0.5 exists because rung 1 reaches containerd through `docker exec`, which is itself
a hijacked stream: if it truncated, rung 1 would say nothing about containerd. It does
not truncate.

Rung 2 — straight at `kubelet:10250` — is **not implemented**. kubelet's exec endpoint
upgrades to SPDY/3.1, which no shell tool speaks, and the repository's constraint is
`kubectl` + `docker` + coreutils. It would split kubelet from apiserver; it would not
change who the issue is filed against. See `lib/kubelet-exec.sh`.

### The control group

kind, two nodes, vanilla Kubernetes with no k3s in the picture: 9/10 truncated at the
baseline cell, while `crictl exec` on the same node, same pod, same reader is 0/5. kind
also runs containerd, so it controls for the distribution and not for the runtime; a
CRI-O control would close that gap and is not here.

### Version matrix

Same cell, eight releases, five runs per transport, all locally in docker
(`results/matrix/`). k3s 1.30 is in the list because it is the release that made
WebSocket the default — the release #60140 believes fixed this.

| release | WebSocket | SPDY | of those, silent |
|---|---|---|---|
| k3s v1.30.14-k3s2 | 5/5 | 2/5 | 3 |
| k3s v1.32.13-k3s1 | 5/5 | 0/5 | 2 |
| k3s v1.34.11-k3s1 | 5/5 | 0/5 | 1 |
| k3s v1.36.4-k3s1 | 5/5 | 2/5 | 2 |
| kind v1.30.13 | 4/5 | 5/5 | 9 |
| kind v1.32.11 | 5/5 | 4/5 | 7 |
| kind v1.34.11 | 4/5 | 3/5 | 6 |
| kind v1.37.0 | 4/5 | 5/5 | 7 |

**No release is clean.** Every one of the eight loses bytes on the default transport, from
the release that introduced it to the newest available. 1.30 did not fix this. Of the 80
runs, 58 truncated and 37 of those did so with exit `0` and an empty stderr.

## Running it

Requires `kubectl`, `docker`, `jq` and coreutils. `kind` is fetched into `.tools/` on
demand. No `pv`, no python, no helm.

```sh
./repro.sh setup --env kind            # or --env k3s-docker, or --env k8s-a
./repro.sh grid  --env kind --sizes 32 --readers slow --transports ws,spdy --runs 5
./repro.sh teardown --env kind

./bisect.sh --sizes 32 --readers slow --runs 5     # the whole ladder, k3s in docker
./matrix.sh kind v1.30.13 v1.32.11                 # version sweep
```

Against your own cluster, add an `env/` file next to `env/k8s-a.sh`; it needs `env_up`,
`env_down` and `env_describe`.

### What the harness measures

- **Payload.** `dd if=/dev/zero bs=1M count=N | tr '\0' 'x'` — deterministic, so the
  expected digest is a constant and loss is measurable in bytes rather than merely
  detectable.
- **Expected values are produced where the payload is produced.** A second exec inside the
  same container computes the size and the sha256; its own output is 80 bytes and
  therefore survives a path that loses megabytes. A short read is a failure regardless of
  exit code — the far end of an exec stream cannot tell truncation from EOF, which is the
  whole defect.
- **Throttle.** A `dd`+`sleep` loop consuming 1 MiB/s (`lib/throttle.sh`).
- **Record.** One CSV row per run: `env, rung, transport, size, reader, drain,
  expected_bytes, got_bytes, lost_bytes, sha_match, exit_code, stderr_len, seconds,
  verdict`.

## Repository layout

```
repro.sh              one cell, one grid, one environment
bisect.sh             the ladder and its branching verdict
matrix.sh             version sweep
lib/                  run, verify, throttle, grid, report, netem, pod
env/                  k8s-a, k3s-docker, kind, baseline
manifests/            the payload pod
results/              every run ever recorded, as CSV
docs/issue-*.md       draft issue text, not filed
.github/workflows/    the same measurements on neutral hardware
```

## Honesty about the limits

- **A green CI run would prove nothing on its own.** One fast runner with client,
  apiserver, kubelet and containerd in a single kernel is the configuration least likely
  to fail. The throttled reader is what makes it fail anyway; `netem` on the docker bridge
  is available for the same reason, where passwordless `sudo` exists. Every result
  recorded here was produced without it.
- **kubelet versus apiserver is unsplit.** The ladder eliminates everything below kubelet,
  and nothing above it.
- **containerd is exonerated only as far as `crictl exec` reaches.** kubelet's CRI proxy
  sits between containerd and the apiserver and is inside the remaining suspect region.
- **One runtime.** Both clean-room environments run containerd. CRI-O is untested.
- **Do not let the workaround become the finding.** Verifying where the data is produced,
  and draining before exit, already protect a fleet. This exists so the defect stops
  needing to be worked around.
