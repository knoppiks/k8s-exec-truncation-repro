<!--
Draft — follow-up 2, Bug Report form. NOT FILED.
File only after the umbrella issue is triaged or a maintainer agrees with the
split. Replace #UMBRELLA with its number.
-->

**Title:** `kubectl exec` exits 0 when the stream ends without an exit status

### What happened?

Split out of #UMBRELLA.

When an exec stream ends before the exit status arrives, `kubectl exec` (and
`crictl exec`) exit 0 and print nothing. On v1.37.0, every short read over SPDY was
reported this way (5/5), and so was every short read from `crictl` against the CRI
streaming server alone (5/5). Over WebSocket, short reads sometimes exit 1 with
`unexpected EOF` and sometimes exit 0, depending on how the connection ends.

### What did you expect to happen?

If the client never received the exit status, it should not report success. A
non-zero exit and a message on stderr would be enough for scripts, backup jobs and
CI pipelines to notice.

### How can we reproduce it (as minimally and precisely as possible)?

The reproduction in #UMBRELLA; look at the exit codes of the SPDY and `crictl` runs.

### Anything else we need to know?

This is separate from the data loss itself. Any interruption, such as a proxy
timeout, a node going away, or a load balancer resetting an idle connection, can end a
stream early. The client should tell "the process finished and I have all of its
output" apart from "the connection ended". Today an empty error stream is read as
success (pointer in #UMBRELLA).

`/sig cli`

### Kubernetes version

As in #UMBRELLA (v1.37.0).
