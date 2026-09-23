#!/usr/bin/env bash
# One measured exec: stream a payload out of a container, count what arrives.
#
# Everything here is deliberately transport-agnostic. The rung being probed is
# selected by $RUNNER, set by the env/ script, so that every rung of the
# bisection ladder runs the identical generator and the identical verification.

# ---------------------------------------------------------------- payload ----

# payload_cmd SIZE_MIB DRAIN_SECONDS
#   Deterministic: SIZE_MIB * 1 MiB of the byte 'x'. The digest is therefore a
#   constant per size and the loss is measurable in bytes, not merely
#   detectable. DRAIN_SECONDS keeps the process alive after its last write,
#   which is the known workaround and therefore the control.
payload_cmd() {
  local size_mib="$1" drain="$2"
  local gen="dd if=/dev/zero bs=1048576 count=${size_mib} 2>/dev/null | tr '\\0' 'x'"
  if [[ "$drain" == "0" ]]; then
    printf '%s\n' "$gen"
  else
    printf '%s; sleep %s\n' "$gen" "$drain"
  fi
}

# digest_cmd SIZE_MIB
#   Same generator, but consumed inside the container. Its own output is 80
#   bytes, so it is trustworthy on a path that truncates large streams.
digest_cmd() {
  local size_mib="$1"
  printf "dd if=/dev/zero bs=1048576 count=%s 2>/dev/null | tr '\\\\0' 'x' | sha256sum | cut -d' ' -f1\n" "$size_mib"
}

# ----------------------------------------------------------------- runner ----

# build_exec_argv REMOTE_SH_COMMAND
#   Fills the global EXEC_ARGV with the argv that streams the command's stdout
#   to the caller's stdout. One case per rung.
build_exec_argv() {
  local cmd="$1"
  case "${RUNNER:-kubectl}" in
    kubectl)
      EXEC_ARGV=(kubectl)
      [[ -n "${KUBE_CONTEXT:-}" ]] && EXEC_ARGV+=(--context "$KUBE_CONTEXT")
      # Verbosity is off by default: -v=7 logs every request and makes the
      # stderr capture the size of the evidence. It is switched on deliberately,
      # for the runs that are meant to be read by a maintainer.
      [[ -n "${KUBECTL_VERBOSITY:-}" ]] && EXEC_ARGV+=("-v=$KUBECTL_VERBOSITY")
      EXEC_ARGV+=(-n "${NAMESPACE:-exec-repro}" exec "${POD:-payload}" -- sh -c "$cmd")
      ;;
    crictl)
      # Rung 1: the runtime's streaming server alone, no kubelet, no apiserver.
      #
      # The reader must sit directly on crictl's stdout, inside the node. Put
      # on the host, behind `docker exec`, it is shielded by docker's attach
      # stream, which absorbs the backlog: crictl then drains the runtime at
      # full speed and the rung reports clean when it is not. So the throttle
      # runs in the node, into a file there, and the file is sent back
      # unthrottled once crictl has finished. The host side reads fast.
      local rate q_cmd
      rate=$(reader_rate "${CURRENT_READER:-fast}") || return 64
      q_cmd=$(printf '%q' "$cmd")
      local in_node
      if [[ "$rate" == 0 ]]; then
        in_node="${CRICTL_CMD:-crictl} exec $CRICTL_ID sh -c $q_cmd"
      else
        # A pipeline's first exit status is not portable to busybox sh, so the
        # exit status of crictl is carried through a file.
        in_node="$(slow_sink_source)
          rm -f /tmp/.crictl-out /tmp/.crictl-rc
          { ${CRICTL_CMD:-crictl} exec $CRICTL_ID sh -c $q_cmd; echo \$? > /tmp/.crictl-rc; } | slow_sink $rate /tmp/.crictl-out
          cat /tmp/.crictl-out
          rc=\$(cat /tmp/.crictl-rc)
          rm -f /tmp/.crictl-out /tmp/.crictl-rc
          exit \$rc"
      fi
      EXEC_ARGV=(docker exec -i "$CRICTL_DOCKER" sh -c "$in_node")
      ;;
    dockerexec)
      # The control for rung 1. Rung 1 reaches containerd through `docker exec`,
      # which is itself a hijacked stream and could lose bytes on its own
      # account. This runs the same generator through docker alone, inside the
      # node container, with no CRI in the path. If this truncates, rung 1 says
      # nothing about containerd.
      EXEC_ARGV=(docker exec -i "$DOCKER_EXEC_TARGET" sh -c "$cmd")
      ;;
    kubelet)
      # Rung 2: straight at kubelet:10250 with a client certificate.
      EXEC_ARGV=("$REPO_ROOT/lib/kubelet-exec.sh" "$cmd")
      ;;
    *)
      printf 'unknown RUNNER: %s\n' "${RUNNER:-}" >&2
      return 64
      ;;
  esac
}

# transport_env TRANSPORT — env assignments for the requested wire protocol.
transport_env() {
  case "$1" in
    ws) printf 'KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true\n' ;;
    spdy) printf 'KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false\n' ;;
    na) printf '\n' ;;
    *)
      printf 'unknown transport: %s\n' "$1" >&2
      return 64
      ;;
  esac
}

# --------------------------------------------------------------- measure -----

# run_once SIZE_MIB READER TRANSPORT DRAIN OUTDIR TAG
#   Sets: RUN_EXPECTED_BYTES RUN_GOT_BYTES RUN_SHA_MATCH RUN_EXIT RUN_STDERR_LEN
#         RUN_SECONDS RUN_VERDICT
run_once() {
  local size_mib="$1" reader="$2" transport="$3" drain="$4" outdir="$5" tag="$6"
  local out="$outdir/$tag.bin" err="$outdir/$tag.err"
  local expected_bytes=$((size_mib * 1024 * 1024))
  local started ended rc

  mkdir -p "$outdir"
  CURRENT_READER=$reader
  build_exec_argv "$(payload_cmd "$size_mib" "$drain")"

  # Runners that throttle in the node deliver an already-drained result, so
  # the host must not throttle it a second time.
  local host_reader=$reader
  [[ "${RUNNER:-kubectl}" == crictl ]] && host_reader=fast

  local -a env_prefix=()
  local t
  t="$(transport_env "$transport")" || return 64
  [[ -n "$t" ]] && env_prefix=(env "$t")

  started=$(date +%s)
  set +e
  "${env_prefix[@]}" timeout --signal=KILL "${RUN_TIMEOUT:-900}" \
    "${EXEC_ARGV[@]}" 2>"$err" | sink "$host_reader" "$out"
  rc=${PIPESTATUS[0]}
  set -e
  ended=$(date +%s)

  RUN_EXIT=$rc
  RUN_SECONDS=$((ended - started))
  RUN_GOT_BYTES=$(stat -c %s "$out")
  RUN_EXPECTED_BYTES=$expected_bytes
  RUN_STDERR_LEN=$(stat -c %s "$err")

  local got_sha
  got_sha=$(sha256sum "$out" | cut -d' ' -f1)
  if [[ "$got_sha" == "$(expected_sha "$size_mib")" ]]; then
    RUN_SHA_MATCH=yes
  else
    RUN_SHA_MATCH=no
  fi

  if [[ "$RUN_GOT_BYTES" == "$expected_bytes" && "$RUN_SHA_MATCH" == yes ]]; then
    RUN_VERDICT=complete
  elif ((RUN_GOT_BYTES < expected_bytes)); then
    RUN_VERDICT=truncated
  else
    RUN_VERDICT=corrupt
  fi

  # The payload is reproducible from its size; the bytes themselves are not
  # evidence. Keep only short reads, and only their tail, for inspection.
  if [[ "$RUN_VERDICT" == complete ]]; then
    rm -f "$out"
  else
    tail -c 4096 "$out" >"$out.tail" 2>/dev/null || true
    rm -f "$out"
  fi
  [[ -s "$err" ]] || rm -f "$err"
}
