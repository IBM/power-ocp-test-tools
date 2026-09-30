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

CLUSTER_NAME="${CLUSTER_NAME:-lbtest}"
HAPROXY_CONTAINER="test-haproxy"
HAPROXY_IMAGE="haproxy:1.8-alpine"   # closest published image to RHEL 8's 1.8.27
PODMAN_NETWORK="kind"
STATS_PORT=19000
APISERVER_PORT=16443
WORKDIR="$(mktemp -d /tmp/haproxy-kind-test.XXXXXX)"
KUBECONFIG_LB="${WORKDIR}/kubeconfig-via-lb.yaml"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

KIND_IMAGE := quay.io/powercloud/kind-node:v1.34.1
#KIND_IMAGE = docker.io/kindest/node:v1.34.1
KIND_CLUSTER_NAME="power-dra-driver-cluster"
KIND_CLUSTER_CONFIG_PATH = "hack/kind-cluster-config.yaml"
KIND_EXPERIMENTAL_PROVIDER:="podman"

log()  { echo "[$(date '+%H:%M:%S.%3N')] $*"; }
need() { command -v "$1" >/dev/null || { echo "missing required tool: $1"; exit 1; }; }

setup_kind() {
    mkdir -p dev-cache
    GOBIN=$(PWD)/dev-cache/ go install sigs.k8s.io/kind@v0.29.0

    KIND_EXPERIMENTAL_PROVIDER=podman dev-cache/kind create cluster \
        --image ${KIND_IMAGE} \
        --name ${KIND_CLUSTER_NAME} \
        --config ${KIND_CLUSTER_CONFIG_PATH} \
        --wait 5m
}

cleanup() {
  [[ -f "${WORKDIR}/watch.pid" ]] && kill "$(cat "${WORKDIR}/watch.pid")" 2>/dev/null || true
  if [[ "${KEEP_CLUSTER}" != "1" ]]; then
    log "tearing down (set KEEP_CLUSTER=1 to skip this)"
    podman rm -f "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true
    KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER} dev-cache/kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
  else
    log "KEEP_CLUSTER=1 set — leaving cluster + haproxy running."
    log "  stats page:  http://127.0.0.1:${STATS_PORT}/"
    log "  kubeconfig:  ${KUBECONFIG_LB}"
    log "  workdir:     ${WORKDIR}"
    log "  teardown manually with: podman rm -f ${HAPROXY_CONTAINER}; kind delete cluster --name ${CLUSTER_NAME}"
  fi
}
trap cleanup EXIT

for t in podman kubectl curl jq bc; do need "$t"; done

# -----------------------------------------------------------------------
# 1. Bring up a 3-control-plane kind cluster: 3 real kube-apiservers on
#    one Podman network.
# -----------------------------------------------------------------------
log "creating 3-control-plane kind cluster '${CLUSTER_NAME}'"
cat <<EOF | KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER} dev-cache/kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: control-plane
  - role: control-plane
EOF

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
# helper: start a long-lived watch, return its container/backend pin
# -----------------------------------------------------------------------
start_watch() {
  local logfile="$1"
  : > "${logfile}"
  stdbuf -oL kubectl --kubeconfig "${KUBECONFIG_LB}" get pods -A --watch \
    > >(while read -r line; do echo "[$(date '+%H:%M:%S.%3N')] ${line}"; done >> "${logfile}") 2>&1 &
  echo $! > "${WORKDIR}/watch.pid"
}

pinned_backend() {
  curl -s "http://127.0.0.1:${STATS_PORT}/;csv" \
    | awk -F',' '$2 ~ /^master/ && $5>0 {print $2}' | head -1
}

# -----------------------------------------------------------------------
# helper: run one full drain test against whichever config is currently
# loaded in haproxy. Returns nothing; logs timings.
# -----------------------------------------------------------------------
run_drain_test() {
  local label="$1" watchlog="${WORKDIR}/watch-${1}.log"

  log "--- ${label}: opening long-lived watch through haproxy ---"
  start_watch "${watchlog}"
  sleep 3

  local target
  target=$(pinned_backend || true)
  if [[ -z "${target:-}" ]]; then
    echo "couldn't determine which backend the watch landed on; skipping this run"
    return
  fi
  # map haproxy server name (master0/1/2) back to the kind node container
  local idx="${target#master}"
  local node_container="${NODES[$idx]}"
  log "watch is pinned to ${target} -> node container ${node_container}"

  local cid
  cid=$(podman exec "${node_container}" crictl ps --name kube-apiserver -q | head -1)
  [[ -n "${cid}" ]] || { echo "couldn't find kube-apiserver container in ${node_container}"; return; }

  local t0 t1 t2
  t0=$(date +%s.%N)
  log "t0: graceful SIGTERM to kube-apiserver in ${node_container}"
  podman exec "${node_container}" crictl stop --timeout 60 "${cid}" >/dev/null &

  log "polling haproxy stats until ${target} is marked DOWN..."
  t1=""
  for _ in $(seq 1 60); do
    state=$(curl -s "http://127.0.0.1:${STATS_PORT}/;csv" | awk -F',' -v s="${target}" '$2==s {print $18}')
    if [[ "${state}" == "DOWN" ]]; then t1=$(date +%s.%N); break; fi
    sleep 0.5
  done
  if [[ -z "${t1}" ]]; then
    log "!! ${target} never went DOWN within 30s — health check may be misconfigured"
  else
    log "t1: haproxy marked ${target} DOWN  (+$(echo "${t1} - ${t0}" | bc)s since SIGTERM)"
  fi

  log "watching for the watch connection to die..."
  t2=""
  for _ in $(seq 1 60); do
    if ! kill -0 "$(cat "${WORKDIR}/watch.pid")" 2>/dev/null; then
      t2=$(date +%s.%N); break
    fi
    sleep 1
  done
  if [[ -z "${t2}" ]]; then
    log "RESULT (${label}): watch connection STILL ALIVE 60s after backend marked DOWN"
  else
    log "RESULT (${label}): watch connection died +$(echo "${t2} - ${t0}" | bc)s since SIGTERM, +$(echo "${t2} - ${t1:-${t2}}" | bc)s since marked DOWN"
  fi

  kill "$(cat "${WORKDIR}/watch.pid")" 2>/dev/null || true
  # give the apiserver container a moment before we start the next node
  sleep 5
}

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
