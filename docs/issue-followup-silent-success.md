# Draft — follow-up 2: a cut-short stream is reported as success

Not filed. Open after the umbrella issue has been acknowledged, and link it.

---

**Title:** `kubectl exec` exits 0 when stdout was cut short

### What happens

When the stdout stream of an exec session ends before all of the process's output has
been delivered, `kubectl exec` still exits with the process's exit code, usually `0`,
and prints nothing. In the reproduction linked from the umbrella issue, 37 of 58 short
reads across eight releases looked like this: exit `0`, empty stderr.

The rest failed loudly (exit `1`, `websocket: close 1006` or `connection reset by
peer`). Which one you get varies between runs, transports and clusters.

### What should happen

If the client cannot confirm that it received the whole stream, it should not report
success. A non-zero exit and a message on stderr would be enough to make every script,
backup job and CI pipeline that relies on `kubectl exec` notice.

### Why this is separate from the data loss

Even after the loss itself is fixed, any other interruption (a proxy timeout, a node
going away, a load balancer resetting an idle connection) can end a stream early. The
client should tell the difference between "the process finished and I have all of its
output" and "the connection ended". Today it cannot, or does not, and so a partial
result is reported as a complete one. That is what makes the data loss dangerous: it
is not noticed until the data is needed.

### Evidence

See the umbrella issue. Short reads with exit `0` and an empty stderr occurred on every
release tested, on both transports, and on GitHub-hosted runners.
