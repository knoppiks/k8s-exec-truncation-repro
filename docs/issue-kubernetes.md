<!--
Draft — kubernetes/kubernetes, Bug Report form. NOT FILED.
Each "### " heading below is one field of the form; paste the section body
into it. Work through docs/before-filing.md first. The two narrower issues are
in issue-followup-*.md and are filed only after this one is triaged.
-->

**Title:** exec drops the end of stdout when the client reads slower than the process writes, often with exit code 0

### What happened?

A process run with `kubectl exec` writes N bytes to stdout and exits 0. When the
client reads more slowly than the process writes, it receives fewer than N bytes: an
intact prefix with the end missing. `kubectl exec` often exits 0 with nothing on
stderr, so the short result cannot be told apart from a complete one.
`kubectl cp` fails in the same situation with `error: unexpected EOF`.

On v1.37.0 (kind, two nodes, kubectl v1.37.0), 32 MiB written and read at 1 MiB/s:

| path | short reads | of those, exit 0 and empty stderr |
|---|---|---|
| `kubectl exec`, WebSocket (default) | 3/5 | 0 |
| `kubectl exec`, SPDY | 5/5 | 5 |
| `crictl exec` on the node, same reader | 5/5 | 5 |
| `crictl exec` on the node, reader not throttled | 0/5 | |
| `kubectl exec`, process sleeps 45 s after its last write | 0/1 | |

The `crictl` row has only the CRI streaming server in the path: no kubelet, no
apiserver, no network.

A client that keeps up does not trigger it, which is probably why #60140 could not be
reproduced with multi-GB copies to a local cluster. A consumer that is slower than the
producer does: a remote client on a thin link, or a slow pipe on the receiving end.

### What did you expect to happen?

Everything the process wrote reaches the client, or the client exits non-zero. A
stream that was cut short should never be reported as a success.

### How can we reproduce it (as minimally and precisely as possible)?

Needs `kind`, `kubectl`, `docker`, `bash`.

```bash
cat <<'EOF' | kind create cluster --name trunc --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes: [{role: control-plane}, {role: worker}]
EOF
kubectl run payload --image=alpine:3.22 --restart=Never \
  --overrides='{"spec":{"nodeName":"trunc-worker"}}' -- sleep infinity
kubectl wait --for=condition=Ready pod/payload --timeout=120s

# The container writes exactly 32 MiB (33554432 bytes) and exits 0.
PAYLOAD='head -c 33554432 /dev/zero'

# A reader that consumes 1 MiB per second and prints how many bytes it got.
slow_count() {
  total=0
  while n=$(head -c 1048576 | wc -c) && [ "$n" -gt 0 ]; do
    total=$((total + n)); sleep 1
  done
  echo "got=$total"
}

# 1) kubectl exec through the apiserver: WebSocket (default), then SPDY.
for ws in true false; do
  echo -n "kubectl exec, websockets=$ws: "
  KUBECTL_REMOTE_COMMAND_WEBSOCKETS=$ws kubectl exec payload -- sh -c "$PAYLOAD" | slow_count
  echo "  kubectl exit code: ${PIPESTATUS[0]}"
done

# 2) The same reader on the node, reading crictl exec directly: only the CRI
#    streaming server is in the path. No kubelet, apiserver or network.
id=$(docker exec trunc-worker crictl ps --name payload -q)
echo -n "crictl exec on the node: "
docker exec trunc-worker bash -c "$(declare -f slow_count)
  crictl exec $id sh -c '$PAYLOAD' | slow_count
  echo \"  crictl exit code: \${PIPESTATUS[0]}\""

# Control: keep the process alive until the reader has caught up.
echo -n "kubectl exec, 'sleep 45' after the last write: "
kubectl exec payload -- sh -c "$PAYLOAD; sleep 45" | slow_count
```

Output from one run:

```
kubectl exec, websockets=true: E0923 14:28:35.600783  237940 v2.go:168] "Copying stderr failed" err="next reader: unexpected EOF"
E0923 14:28:35.600783  237940 v2.go:151] "Copying stdout failed" err="next reader: unexpected EOF"
error: error reading from error stream: next reader: unexpected EOF
got=31860075
  kubectl exit code: 1
kubectl exec, websockets=false: got=32998850
  kubectl exit code: 0
crictl exec on the node: got=32429975
  crictl exit code: 0
kubectl exec, 'sleep 45' after the last write: got=33554432
```

Fuller measurements, per-hop packet captures and scripts:
https://github.com/knoppiks/k8s-exec-truncation-repro

### Anything else we need to know?

**What the loss looks like.** The process is not killed: in every short read it had
written everything and exited 0 (checked from inside the container afterwards). A
`seq` stream arrives as exactly `1 … k` with no gaps, so it is the end that goes
missing, not something in the middle. How much is lost depends on how far behind the
reader is when the process exits.

**Where it happens.** Packet captures on both nodes during six short reads (v1.37.0)
show the kubelet passing on everything it received, every time. Bytes were lost in
two places:

- **CRI streaming server → kubelet**, twice: the connection was reset (RST, no FIN)
  before everything had been sent. The same happens with `crictl` alone (the table
  above). On the node, the kernel's `TcpExtTCPAbortOnData` counter goes up by exactly
  one for each short `crictl` read and not at all for complete ones.
- **apiserver → client**, four times: the apiserver sent the client less than it had
  received from the kubelet, three times ending with an RST.

**Code pointers** (my reading, links pinned to v1.37.0):

<details>

- The CRI streaming server closes the connection as soon as the exec finishes and
  the status is written, without waiting for the peer to read what is still queued:
  [`defer ctx.conn.Close()` in `ServeExec`](https://github.com/kubernetes/kubernetes/blob/f54c212e3a2f75d674b717a9b29052b20b60aefc/staging/src/k8s.io/cri-streaming/pkg/streaming/remotecommand/exec.go#L46).
  The client is still behind, so it is still sending (flow control, pings). Data
  arriving on a closed socket makes Linux reset the connection and throw away what
  was still unsent. That matches the counter above.
- The apiserver proxies exec through `UpgradeAwareHandler` for both transports on
  1.37 (`apiserver_websocket_streaming_requests_total{proxy_type="proxied_to_kubelet",subresource="exec"}`
  counted the WebSocket runs). Its copy loop ends the whole session as soon as
  *either* direction finishes:
  [`select` on `writerComplete` / `readerComplete`](https://github.com/kubernetes/kubernetes/blob/f54c212e3a2f75d674b717a9b29052b20b60aefc/staging/src/k8s.io/apimachinery/pkg/util/proxy/upgradeaware.go#L447-L452),
  followed by the deferred closes of both connections
  ([L348](https://github.com/kubernetes/kubernetes/blob/f54c212e3a2f75d674b717a9b29052b20b60aefc/staging/src/k8s.io/apimachinery/pkg/util/proxy/upgradeaware.go#L348),
  [L386](https://github.com/kubernetes/kubernetes/blob/f54c212e3a2f75d674b717a9b29052b20b60aefc/staging/src/k8s.io/apimachinery/pkg/util/proxy/upgradeaware.go#L386)).
  When the kubelet side closes, the kubelet→client direction can still hold data.
  This fits the captures; I have not traced it inside the apiserver.
- The exit code: when the error stream ends without a status message, client-go
  treats that as success:
  [`default: errorChan <- nil`](https://github.com/kubernetes/kubernetes/blob/f54c212e3a2f75d674b717a9b29052b20b60aefc/staging/src/k8s.io/client-go/tools/remotecommand/errorstream.go#L48-L49).
  The status is written after stdout, so it is lost together with the end of stdout,
  and the result reads as exit 0.

</details>

**Proposed split.** There are two separate problems here, and I would like to follow
up with one issue and PR(s) for each, if maintainers agree:

1. Output that has been written is dropped when the session ends before the reader
   has caught up (CRI streaming server and apiserver proxy).
2. A stream that ends without an exit status is reported as success.

Fixing 2 makes the failure visible. Fixing 1 stops it happening.

**Affected releases.** Same measurement on kind v1.30.13, v1.32.11, v1.34.11 and
v1.37.0, and on k3s v1.30–v1.36. Every release loses bytes; 1.30, which made
WebSocket the default, is not better. Also seen on GitHub-hosted runners and on a
three-node k3s cluster over a LAN.

**Related.** #60140 (`kubectl cp` fails on large files, closed as not reproducible)
and #124571 (`kubectl exec` truncates stdout without reporting error, closed as
stale) describe this.

containerd#13934 (a duplicate of containerd#12734) looks similar but is a different
bug. There, stdin is cut short because containerd's exec IO closes the stdin stream
as soon as the process's stdout reaches EOF; containerd#12733 proposes a fix in
containerd. Here stdin is not used at all, the process keeps stdout open until it
exits, and the output reaches the streaming server intact. The two share only the
last step: the connection is closed while the peer is still sending, and the kernel
resets it.

This is data loss, not a security issue, so I am reporting it here.

The investigation was done with the help of AI tooling. I have reproduced the results
above myself.

### Kubernetes version

<details>

```console
$ kubectl version
Client Version: v1.37.0
Kustomize Version: v5.8.1
Server Version: v1.37.0
```

</details>

### Cloud provider

<details>
None: kind v0.33.0 (two nodes) on a local docker host.
</details>

### OS version

<details>

The kind nodes are containers on one host: they share the host's kernel, and only
their userland comes from the node image.

```console
# Host (runs docker, the kind nodes and kubectl)
$ cat /etc/os-release
PRETTY_NAME="Ubuntu 26.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION="26.04.1 LTS (Resolute Raccoon)"
VERSION_CODENAME=resolute
ID=ubuntu
ID_LIKE=debian
$ uname -srvmo
Linux 7.0.0-31-generic #31-Ubuntu SMP PREEMPT_DYNAMIC Sat Aug  1 04:26:38 UTC 2026 x86_64 GNU/Linux

# kind node image (kindest/node:v1.37.0), userland only
$ cat /etc/os-release
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
VERSION_ID="13"
DEBIAN_VERSION_FULL=13.6
ID=debian
```

Also reproduced on a three-node k3s cluster on Debian 13, kernel
`6.12.74+deb13+1-amd64`.

</details>

### Install tools

<details>
kind v0.33.0, node image kindest/node:v1.37.0
</details>

### Container runtime (CRI) and version (if applicable)

<details>

```console
$ crictl version
Version:  0.1.0
RuntimeName:  containerd
RuntimeVersion:  v2.3.4
RuntimeApiVersion:  v1
```

</details>

### Related plugins (CNI, CSI, ...) and versions (if applicable)

<details>
kind defaults (kindnet). Not involved: the loss also occurs with crictl on the node.
</details>

<!--
After filing, as a separate comment (each command on its own line):

/sig node
/sig api-machinery
/sig cli

And one line on #60140 linking the new issue.
-->
