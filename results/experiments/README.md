# Experiments

All on a two-node kind cluster (v1.37.0, containerd 2.3.4), pod on the worker,
32 MiB of payload read at 1 MiB/s unless stated. Each CSV is produced by the
script of the same name in `experiments/`.

## `writer-vs-transit-kind.csv` — was the writer killed?

No. The payload is written to a file in the pod, streamed with `cat`, and `cat`'s
exit status is read from inside the container afterwards. In 10/10 short reads
`cat` had written all 33 554 432 bytes and exited `0`.

## `where-is-the-hole-kind.csv` — where in the stream is the loss?

At the end. `seq 1 4000000` arrives as exactly `1 … k` with no gaps (6/6),
sometimes ending mid-number.

## `verbose/` — what does the client see?

`kubectl -v=7` for one short read per transport. WebSocket ends with
`"Closed channel -- returning"`, SPDY with `SPDY Ping failed: connection closed`.

## `kubectl-cp-*.csv` — does `kubectl cp` lose data?

| client | file | WebSocket | SPDY |
|---|---|---|---|
| same host, local disk | 1 GiB | 0/3 | 0/3 |
| own container, ingress policed to 20 Mbit/s | 256 MiB | 3/3 | 1/3 |

Every failed copy exited `1` with `error: unexpected EOF`.

## `crictl-in-node-kind.csv` — the streaming server alone

`crictl exec` run on the worker node, with the throttled reader in the node
directly on crictl's stdout. No kubelet, apiserver or network in the path.

| reader | drain | result |
|---|---|---|
| 1 MiB/s | none | **3/3 truncated, all exit 0** |
| 1 MiB/s | `sleep 45` | 2/2 complete |
| unthrottled | none | 2/2 complete |

The worker's `TcpExtTCPAbortOnData` counter rose by exactly 3 across the three
truncated runs (31 → 34), and not at all across the controls: in each short
read, a socket that its owner had already closed received more data, and the
kernel aborted the connection with an RST, discarding what it had not yet sent.

The original rung 1 of the ladder reported this hop clean. It ran
`docker exec -i <node> crictl exec … | slow reader` on the host, where docker's
attach stream absorbed the backlog and crictl drained the streaming server at
full speed. `lib/run.sh` now runs the reader inside the node.

## `packet-trace/` — which hop drops the bytes, and how does it close?

Header-only captures on both nodes during each run: bytes each hop carried (from
TCP sequence numbers, so TLS and stream framing are included — expect ~1 % above
the payload), and whether each sender closed with FIN (graceful) or RST (abort,
which discards what the sender's kernel still held). `hops.csv` has every run;
the pcaps are in the per-run directories.

| run | client got | streaming server → kubelet | kubelet → apiserver | apiserver → client | where the bytes were lost |
|---|---|---|---|---|---|
| ws 1 | 33.22 MB | 33.66 MB, FIN then RST | 33.96 MB | 33.62 MB, **RST** | apiserver → client |
| ws 2 | 30.86 MB | **30.95 MB, RST** | 31.19 MB | 31.19 MB | streaming server |
| ws 3 | 27.92 MB | **31.37 MB, RST** | 31.62 MB | 31.62 MB, FIN then RST | streaming server, then apiserver → client |
| spdy 1 | 29.85 MB | 33.65 MB, FIN | 33.72 MB | **30.03 MB, RST** | apiserver → client |
| spdy 2 | 32.74 MB | 33.66 MB, FIN | 33.72 MB | **32.91 MB, RST** | apiserver → client |
| spdy 3 | 33.22 MB | 33.66 MB, FIN | 33.72 MB | **33.39 MB**, FIN | inside the apiserver |
| ws, `sleep 45` | complete | 33.67 MB, FIN then RST | 33.98 MB | 33.98 MB, FIN then RST | — |
| spdy, `sleep 45` | complete | 33.66 MB, FIN | 33.72 MB | 33.72 MB, RST | — |

(MB = 10⁶ bytes. Payload is 33.55 MB.)

The kubelet forwarded everything it received in every run. The bytes were lost
at two places: the CRI streaming server, and the apiserver's hop to the client.
Both end their connection while the reader is still behind, and in the drained
controls the very same RSTs occur harmlessly, because by then nothing is left in
flight.
