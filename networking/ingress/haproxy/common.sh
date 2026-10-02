#!/usr/bin/env bash

HAPROXY_CONTAINER="test-haproxy"
HAPROXY_IMAGE="haproxy:1.8-alpine"   # closest published image to RHEL 8's 1.8.27
PODMAN_NETWORK="kind"
STATS_PORT=19000
APISERVER_PORT=16443
WORKDIR="$(mktemp -d /tmp/haproxy-kind-test.XXXXXX)"
KUBECONFIG_LB="${WORKDIR}/kubeconfig-via-lb.yaml"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"

KIND_IMAGE="quay.io/powercloud/kind-node:v1.36.5"
if [ "$(arch)" != "ppc64le" ]
then
    KIND_IMAGE="docker.io/kindest/node:v1.36.5"
fi
KIND_CLUSTER_NAME="haproxy-cluster"
KIND_EXPERIMENTAL_PROVIDER="podman"

log()  { echo "[$(date '+%H:%M:%S.%3N')] $*"; }

# Bring up a 3-control-plane kind cluster: 3 real kube-apiservers on one Podman network.
setup_kind() {
    log "creating 3-control-plane kind cluster '${KIND_CLUSTER_NAME}'"

    #GOBIN=$(pwd)/dev-cache/ go install sigs.k8s.io/kind@v0.29.0

    KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster \
        --image ${KIND_IMAGE} \
        --name ${KIND_CLUSTER_NAME} \
        --config cluster-config.yaml \
        --wait 5m
}

cleanup() {
  [[ -f "${WORKDIR}/watch.pid" ]] && kill "$(cat "${WORKDIR}/watch.pid")" 2>/dev/null || true
  if [[ "${KEEP_CLUSTER}" != "1" ]]; then
    log "tearing down (set KEEP_CLUSTER=1 to skip this)"
    podman rm -f "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true
    KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER} kind delete cluster --name "${KIND_CLUSTER_NAME}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
  else
    log "KEEP_CLUSTER=1 set — leaving cluster + haproxy running."
    log "  stats page:  http://127.0.0.1:${STATS_PORT}/"
    log "  kubeconfig:  ${KUBECONFIG_LB}"
    log "  workdir:     ${WORKDIR}"
    log "  teardown manually with: podman rm -f ${HAPROXY_CONTAINER}; kind delete cluster --name ${KIND_CLUSTER_NAME}"
  fi
}

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

generate_live_config() {
  log "discovering control-plane node IPs on the '${PODMAN_NETWORK}' network"

  local nodes=()
  mapfile -t nodes < <(kind get nodes --name "${KIND_CLUSTER_NAME}" | grep 'control-plane' | sort)

  if ((${#nodes[@]} == 0)); then
    log "ERROR: No control-plane nodes found for cluster '${KIND_CLUSTER_NAME}'"
    return 1
  fi

  # Single podman inspect call for all nodes
  local ips=()
  mapfile -t ips < <(podman inspect -f "{{.NetworkSettings.Networks.${PODMAN_NETWORK}.IPAddress}}" "${nodes[@]}")

  # Build sed replacement expressions and log output in one pass
  local sed_args=()
  for i in "${!ips[@]}"; do
    local node="${nodes[i]}"
    local ip="${ips[i]}"
    log "  ${node} -> ${ip}:6443"
    sed_args+=(-e "s/MASTER${i}_IP/${ip}/g")
  done

  # Perform all replacements in a single sed invocation
  sed "${sed_args[@]}" "${WORKDIR}/haproxy-live.cfg" > "${WORKDIR}/haproxy-live.cfg.tmp" && \
    mv "${WORKDIR}/haproxy-live.cfg.tmp" "${WORKDIR}/haproxy-live.cfg"
}