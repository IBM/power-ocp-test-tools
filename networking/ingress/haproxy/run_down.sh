#!/usr/bin/env bash

# Testing assume setup is complete and the haproxy container is created.

set -euo pipefail
source common.sh

HAPROXY_CONTAINER="haproxy"
HAPROXY_IMAGE="localhost/haproxy-custom:latest"

# -----------------------------------------------------------------------
# 1. Run A: current config, WITH on-marked-down shutdown-sessions
# -----------------------------------------------------------------------
run_drain_test "A_with_on_marked_down"

log "=== DONE ==="
log "With the fix, the watch should die within ~0-1s of the backend being marked DOWN."
