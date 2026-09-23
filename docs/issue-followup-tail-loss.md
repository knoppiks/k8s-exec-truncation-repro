# Draft — follow-up 1: output dropped after the process exits

Not filed. Open after the umbrella issue has been acknowledged, and link it.

---

**Title:** exec drops stdout that has been written but not yet read by the client when the process exits

### What happens

When a process run through exec exits, stdout it has already written but the client
has not yet received is discarded. The client gets an intact prefix of the stream; the
end is missing. How much is missing depends on how far behind the client is.

### What should happen

Everything the process wrote to stdout should reach the client, whether or not the
process has exited. The stream should close after the last byte has been delivered, not
when the process exits.

### Why it matters

Getting data out of a pod with `kubectl exec … > file` and `kubectl cp` is how many
users take backups and export data. Both lose the end of the stream when the client is
slower than the container: a slow consumer on the pipe, or a remote client on a thin
link. The only workaround is to keep the process alive until the client has caught up,
and nobody can know from inside the container how long that takes.

### Evidence

See the umbrella issue. In short: the writer exits `0` having written everything; the
received stream is an exact prefix; the container runtime's streaming server delivers
the full stream to the same slow reader; and the loss appears once the kubelet and
apiserver are in the path, on every release from 1.30 to 1.37.
