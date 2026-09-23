# Draft — kubernetes/kubernetes, umbrella issue

Not filed. This is the general report. The two narrower issues it gives rise to
are drafted in `issue-followup-tail-loss.md` and `issue-followup-silent-success.md`,
to be opened once this one is acknowledged, each with a PR.

---

**Title:** exec streams drop the end of stdout when the client reads slower than the container writes, and usually report success

### What happens

A process in a container writes N bytes to stdout and exits `0`. The client
receives fewer than N bytes. `kubectl exec` usually exits `0` with an empty stderr,
so the short result looks exactly like a complete one. `kubectl cp` fails with
`error: unexpected EOF`, which is the symptom reported in #60140.

It happens when the client reads slower than the container writes: a slow consumer,
a thin link, or a large payload that outruns either. A client reading at
line rate from a nearby apiserver does not hit it, which is why it has been hard to
reproduce on demand.

### What should happen

Either the client receives all N bytes, or it exits non-zero. A stream that is cut
short must not be reported as a success, because the receiver cannot know how long
the stream should have been.

### Reproduction

Needs `kubectl`, `docker`, `jq` and coreutils. Creates a two-node kind cluster.

```
git clone https://github.com/knoppiks/k8s-exec-truncation-repro
cd k8s-exec-truncation-repro
./repro.sh setup --env kind
./repro.sh grid --env kind --sizes 32 --readers slow --transports ws,spdy --runs 5
```

The container writes 32 MiB of a deterministic payload; the client reads it at
1 MiB/s. Expected size and sha256 are computed by a second exec inside the container,
whose own output is 80 bytes. On a two-node kind cluster, v1.37.0, 9 of 10 runs come
up short.

### What the loss looks like

- **The process finished.** In every short read, the writer inside the container had
  written everything and exited `0`. It was not killed. (10/10)
- **The start is intact and the end is missing.** A `seq 1 4000000` stream arrives as
  exactly `1 … k` for some k, with no gaps, sometimes cut in the middle of a number.
  Nothing is dropped from the middle of the stream. (6/6)
- **The amount lost tracks what the client had not read yet.** Typically 1–8 MB of a
  32 MiB stream at 1 MiB/s. Keeping the process alive after its last write stops the
  loss, but only if the delay is longer than the client needs to catch up. On the LAN
  cluster, `sleep 5` did not stop it at 1 MiB/s (4/6 still short), and `sleep 45` did
  (6/6 complete).
- **The client sees the connection close normally.** With `-v=7`, a failing WebSocket
  run ends in `"Closed channel -- returning"` and a failing SPDY run in
  `SPDY Ping failed: connection closed`. Neither logs an error about the stream
  itself. Logs are in the repository under `results/experiments/verbose/`.

In short: output that the process has already written is dropped once the process
exits, if the client has not read it yet.

### Where it is not

Each step below adds one component to the path. Same pod, payload, reader and
verification throughout. 32 MiB at 1 MiB/s, 5 runs per transport:

| path | short reads |
|---|---|
| hash computed inside the pod | 0/1 |
| `docker exec` into the node | 0/5 |
| `crictl exec` on the node, to the container runtime's streaming server | 0/5 |
| `kubectl exec` through the apiserver, k3s | 6/10 |
| same, with k3s's apiserver-to-kubelet tunnel disabled | 9/10 |
| `kubectl exec` through the apiserver, kind | 9/10 |

The container runtime sends the full stream to a slow reader every time. Bytes go
missing only when the apiserver and the kubelet are in the path. It is not specific to
one distribution.

### Which releases

| release | WebSocket | SPDY |
|---|---|---|
| kind v1.30.13 | 4/5 | 5/5 |
| kind v1.32.11 | 5/5 | 4/5 |
| kind v1.34.11 | 4/5 | 3/5 |
| kind v1.37.0 | 4/5 | 5/5 |
| k3s v1.30.14 | 5/5 | 2/5 |
| k3s v1.32.13 | 5/5 | 0/5 |
| k3s v1.34.11 | 5/5 | 0/5 |
| k3s v1.36.4 | 5/5 | 2/5 |

On GitHub-hosted runners (with 20 ms of latency added between the nodes), 30 of 40
runs came up short across k3s 1.30–1.36 and kind. 1.30, which made WebSocket the
default, did not fix this.

### `kubectl cp`

| `kubectl cp` client | file | WebSocket | SPDY |
|---|---|---|---|
| same host, writing to local disk | 1 GiB | 0/3 | 0/3 |
| behind a 20 Mbit/s link | 256 MiB | 3/3 | 1/3 |

A fast local client never triggered it, even with a four times larger file. A client
behind a thin link did in 4 of 6 copies. Each failed copy exited `1` with
`error: unexpected EOF`: `cp` notices because the tar stream ends early, which a raw
`kubectl exec` cannot do.

### Relation to existing issues

- **#60140** was closed in 2025 because it could not be reproduced with multi-GB copies
  to a local cluster. That setup has no slow reader, and it did not fail in the table
  above either. This report supplies the missing ingredient and the logs that
  were asked for there.
- **#124571** (`kubectl exec` truncates stdout without reporting an error) was closed
  as stale and redirected to #60140. It describes the same problem.
- **containerd#13934** is the stdin counterpart. The containerd streaming server
  delivers stdout correctly in the reproduction above.

### Proposed follow-ups

Two separate defects are visible here. Each can be fixed on its own:

1. **Output is dropped after the process exits.** Output the process has written
   should reach the client even if the process exits before the client has read it.
2. **The client reports success anyway.** If the stream ended before all output was
   delivered, the client should not report the process's success as its own.

Fixing 2 alone would make the failure visible. Fixing 1 would stop it happening. I
plan to open both as separate issues with PRs.

### Environment

- kind v0.33.0; node images v1.30.13, v1.32.11, v1.34.11, v1.37.0; containerd 2.3.4
- k3s v1.30.14–v1.36.4 in docker, and a three-node k3s v1.36.4 cluster on a LAN
- `kubectl` v1.36.4
