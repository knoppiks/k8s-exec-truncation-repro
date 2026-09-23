# CI runs

Downloaded from the workflow artifacts. The run ID in each directory name is
the GitHub Actions run that produced it:
`https://github.com/knoppiks/k8s-exec-truncation-repro/actions/runs/<id>`.

Both runs: 32 MiB, 1 MiB/s reader, one run per cell, `ubuntu-latest`,
20 ms netem delay on the docker bridge.

- `run-35825454478-matrix/` — k3s 1.30/1.32/1.34/1.36 × egress agent/disabled,
  k3s 1.36 with the pod on the server node, and kind. Transports ws and spdy,
  drain 0 s and 5 s.
- `run-35825462203-bisect/` — the full ladder on k3s 1.36, with its verdict.
