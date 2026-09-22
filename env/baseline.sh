#!/usr/bin/env bash
# The cell Phase 0 chose, on 2026-09-22, against k8s-a.
#
# Sourced by bisect.sh and by CI so that every later measurement is sized by
# what was measured rather than by the 160 MB that happened to be tried first.
#
#   32 MiB, drained at 1 MiB/s, no drain delay:
#     WebSocket  3/3 truncated, loudly  (exit 1, websocket close 1006)
#     SPDY       2/3 truncated, silently (exit 0, empty stderr)
#
# Cost: 32 seconds and 32 MiB per run. The 128 MiB cells fail no more reliably
# and cost four times as much; the 8 MiB cells fail 1/12.
BASELINE_SIZES=32
BASELINE_READERS=slow
BASELINE_TRANSPORTS=ws,spdy
BASELINE_DRAINS=0
BASELINE_RUNS=5
