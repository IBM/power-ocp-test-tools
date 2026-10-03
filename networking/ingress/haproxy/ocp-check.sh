#!/usr/bin/env bash

# Testing uses RHEL10.2 haproxy setup/configuration

set -euo pipefail

APISERVER_PORT=16443
STATS_PORT=19000
HAPROXY_CONTAINER="haproxy"
HAPROXY_IMAGE="localhost/haproxy-custom:latest"

# logs out with date/time prefix
log()  { echo "[$(date '+%H:%M:%S.%3N')] $*"; }

# -----------------------------------------------------------------------
# Generate HAPROXY Configuration for Test
# -----------------------------------------------------------------------

cat << EOF > haproxy-live.cfg
global
    log         127.0.0.1 local2
    maxconn     20000
    daemon

defaults
    mode                    tcp
    log                     global
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout http-request    10s
    timeout queue           1m
    timeout connect         10s
    timeout client          1h
    timeout server          1h
    timeout check           10s
    maxconn                 20000

frontend api-server-6443
    bind *:16443
    mode tcp
    option tcplog
    default_backend api-server-6443

backend api-server-6443
    mode tcp
    balance roundrobin
    option httpchk
    http-check send meth GET uri /readyz ver HTTP/1.1 hdr Host localhost
    http-check expect status 200
    default-server inter 5s fall 3 rise 2 check-ssl verify none on-marked-down shutdown-sessions
EOF

# Iterates over the control plane node ips to build 
counter=0
for NODE_IP in $(kubectl get nodes -owide -lnode-role.kubernetes.io/master= --no-headers | awk '{print $6}')
do
    echo "    server master${counter} ${NODE_IP}:6443 check" >> haproxy-live.cfg
    ((counter++))  # Increment the index counter
done

cat << EOF >> haproxy-live.cfg
listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /
    stats refresh 10s
EOF

# -----------------------------------------------------------------------
# Build Container
# -----------------------------------------------------------------------

log "building haproxy container '${HAPROXY_CONTAINER}'"
podman build -t haproxy-custom:latest -f Containerfile .

log "removing prior haproxy container '${HAPROXY_CONTAINER}'"
podman rm -f "${HAPROXY_CONTAINER}" >/dev/null 2>&1 || true

log "starting haproxy container '${HAPROXY_CONTAINER}'"
podman run -d --name "${HAPROXY_CONTAINER}" --network host \
  -p "${APISERVER_PORT}:16443" -p "${STATS_PORT}:9000" \
  "${HAPROXY_IMAGE}" >/dev/null

log "done setting up haproxy for testing"

# -----------------------------------------------------------------------
# helper: run one full drain test against whichever config is currently
# loaded in haproxy. Returns nothing; logs timings.
# -----------------------------------------------------------------------

log "looking for the first pid for kube-apiserver"

POD=$(oc get pod -n openshift-kube-apiserver -l app=openshift-kube-apiserver --no-headers| head -n 1 | awk '{print $1}')
PID=$(oc rsh -n openshift-kube-apiserver ${POD} pgrep kube-apiserver)
oc rsh -n openshift-kube-apiserver ${POD} kill ${PID}

target=$(kubectl get nodes -owide -lnode-role.kubernetes.io/master= --no-headers | awk '{print $6}' | head -n 1)
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
