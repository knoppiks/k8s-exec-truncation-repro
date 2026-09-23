<!--
Draft — follow-up 1, Bug Report form. NOT FILED.
File only after the umbrella issue is triaged or a maintainer agrees with the
split. Replace #UMBRELLA with its number.
-->

**Title:** exec output still queued when the process exits is discarded

### What happened?

Split out of #UMBRELLA.

When an exec'd process exits while the client is still behind, the output that has
been written but not yet delivered is discarded. The client gets an intact prefix;
the end is missing.

It happens at two points on the path, and each loses bytes on its own:

- the **CRI streaming server**, with nothing else involved (`crictl exec` on the node
  with a slow reader: 5/5 short on v1.37.0);
- the **apiserver**, on its connection to the client, even when everything reached it
  intact from the kubelet.

In both cases the session ends with the connection being closed while the peer is
still sending, and the connection is reset with output still unsent.

### What did you expect to happen?

Everything the process wrote reaches the client. The stream ends after the last byte
has been delivered, not when the process exits.

### How can we reproduce it (as minimally and precisely as possible)?

The reproduction in #UMBRELLA. Section 2 of it (`crictl exec` on the node) is enough
for the streaming server alone.

### Anything else we need to know?

See the code pointers in #UMBRELLA. Both places close a connection that still has
traffic in the other direction. A fix would half-close the sending side and keep
reading until the peer closes (a "lingering close"), rather than closing outright.

I plan to send two PRs, one for the streaming server (`/sig node`) and one for the
apiserver proxy (`/sig api-machinery`).

### Kubernetes version

As in #UMBRELLA (v1.37.0).
