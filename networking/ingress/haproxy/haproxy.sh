#!/usr/bin/env bash

# The test follows this pattern:
# 
# 1. creates 3-control-plane kind cluster, puts a real
# 2. loads haproxy.cfg (embedded below) in front of the 3 apiservers
# 3. opens a long-lived HTTP/2 watch through it
# 4. gracefully SIGTERMs one apiserver to simulate /readyz -> false during shutdown
#       - Ref the scenario in openshift/cluster-kube-apiserver-operator#2222)
#       - times how long it takes haproxy to mark that backend DOWN
#       - times how long it takes the watch connection to actually die
# 5. re-runs the same test with `on-marked-down shutdown-sessions` excluded
#
# Requirements: podman, kind, kubectl, curl, jq, bc
#
# Usage: ./test.sh

set -euo pipefail

source common.sh
trap cleanup EXIT

log "discovering control-plane node IPs on the '${PODMAN_NETWORK}' network"
mapfile -t NODES < <(dev-cache/kind get nodes --name "${CLUSTER_NAME}" | grep control-plane | sort)
IPS=()
for n in "${NODES[@]}"; do
  ip=$(podman inspect -f "{{.NetworkSettings.Networks.${PODMAN_NETWORK}.IPAddress}}" "${n}")
  IPS+=("${ip}")
  log "  ${n} -> ${ip}:6443"
done

i=0
for ip in "${IPS[@]}"; do
  sed -i "s/MASTER${i}_IP/${ip}/g" "${WORKDIR}/haproxy-live.cfg"
  i=$((i+1))
done
# second copy with the fix stripped out, for the A/B comparison later
sed -E 's/ on-marked-down shutdown-sessions//' "${WORKDIR}/haproxy-live.cfg" > "${WORKDIR}/haproxy-no-omd.cfg"

# -----------------------------------------------------------------------
# 2. Run haproxy in front of the 3 apiservers.
# -----------------------------------------------------------------------
log "starting haproxy container '${HAPROXY_CONTAINER}'"
podman rm -f "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true
podman run -d --name "${HAPROXY_CONTAINER}" --network "${PODMAN_NETWORK}" \
  -p "${APISERVER_PORT}:6443" -p "${STATS_PORT}:9000" \
  -v "${WORKDIR}/haproxy-live.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "${HAPROXY_IMAGE}" >/dev/null
sleep 2

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
  echo "not all backends came up healthy — aborting"; exit 1
fi

# -----------------------------------------------------------------------
# 3. Kubeconfig pointed at haproxy instead of kind's own LB. TCP-mode
#    passthrough preserves the real apiserver TLS handshake, so the
#    existing client cert / CA data stays valid — only the URL changes.
# -----------------------------------------------------------------------
log "building kubeconfig pointed at haproxy"
dev-cache/kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_LB}"
sed -i -E "s#server: https://[^ ]+#server: https://127.0.0.1:${APISERVER_PORT}#" "${KUBECONFIG_LB}"

log "sanity check: kubectl through haproxy"
kubectl --kubeconfig "${KUBECONFIG_LB}" get nodes

# -----------------------------------------------------------------------
# 5. Run A: current config, WITH on-marked-down shutdown-sessions
# -----------------------------------------------------------------------
run_drain_test "A_with_on_marked_down"

# -----------------------------------------------------------------------
# 6. Reload haproxy with the fix stripped out, run B for comparison.
#    (Only 2 of the 3 apiservers are still alive at this point since we
#    stopped one in run A — that's fine, the other two are enough to
#    prove the point for run B.)
# -----------------------------------------------------------------------
log "reloading haproxy WITHOUT on-marked-down shutdown-sessions"
podman cp "${WORKDIR}/haproxy-no-omd.cfg" "${HAPROXY_CONTAINER}:/usr/local/etc/haproxy/haproxy.cfg"
podman kill -s HUP "${HAPROXY_CONTAINER}" >/dev/null
sleep 2

run_drain_test "B_without_on_marked_down"

log "=== DONE. Compare the two RESULT lines above. ==="
log "With the fix, the watch should die within ~0-1s of the backend being marked DOWN."
log "Without it, the watch should stay alive well past that point."
