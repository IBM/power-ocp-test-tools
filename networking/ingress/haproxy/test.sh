#!/usr/bin/env bash

# Testing assume setup is complete and the haproxy container is created.

set -euo pipefail
source common.sh

HAPROXY_CONTAINER="haproxy"
HAPROXY_IMAGE="localhost/haproxy-custom:latest"

# -----------------------------------------------------------------------
# 1. Run haproxy in front of the 3 apiservers.
# -----------------------------------------------------------------------
log "starting haproxy container '${HAPROXY_CONTAINER}'"
podman rm -f "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true
podman run -d --name "${HAPROXY_CONTAINER}" --network "${PODMAN_NETWORK}" \
  -p "${APISERVER_PORT}:16443" -p "${STATS_PORT}:9000" \
  -v "$(pwd)/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "${HAPROXY_IMAGE}" >/dev/null
sleep 2

set -x

log "waiting for haproxy to mark all 3 backends UP"
up=0
for _ in $(seq 1 15); do
  up=$(curl -s "http://127.0.0.1:${STATS_PORT}/;csv" | awk -F',' '$2!="BACKEND" && $2!="stats" && $18=="UP"' | wc -l)
  [[ "${up}" -eq 3 ]] && break
  sleep 2
done
log "backends UP: ${up}/3"
curl -s "http://127.0.0.1:${STATS_PORT}/;csv" | awk -F',' '$2 ~ /^master/ {print "  "$2, $18}'
if [[ "${up}" -ne 3 ]]; then
  echo "not all backends came up healthy — aborting"; return 1
fi

# -----------------------------------------------------------------------
# 2. Kubeconfig pointed at haproxy instead of kind's own LB. TCP-mode
#    passthrough preserves the real apiserver TLS handshake, so the
#    existing client cert / CA data stays valid — only the URL changes.
# -----------------------------------------------------------------------
log "building kubeconfig pointed at haproxy"
kind get kubeconfig --name "${KIND_CLUSTER_NAME}" > "${KUBECONFIG_LB}"
sed -i -E "s#server: https://[^ ]+#server: https://127.0.0.1:${APISERVER_PORT}#" "${KUBECONFIG_LB}"

log "sanity check: kubectl through haproxy"
kubectl --kubeconfig "${KUBECONFIG_LB}" get nodes

# -----------------------------------------------------------------------
# 3. Run A: current config, WITH on-marked-down shutdown-sessions
# -----------------------------------------------------------------------
run_drain_test "A_with_on_marked_down"

log "=== DONE ==="
log "With the fix, the watch should die within ~0-1s of the backend being marked DOWN."
