# HAProxy `on-marked-down shutdown-sessions` kube-apiserver Test

This test validates that HAProxy's `on-marked-down shutdown-sessions` directive
correctly tears down long-lived HTTP/2 watch connections when a backend
kube-apiserver goes down.

It:
1. Creates a 3-control-plane kind cluster backed by real kube-apiservers
2. Builds a custom HAProxy container and places it in front of the 3 apiservers
3. Opens a long-lived `kubectl get pods --watch` through the HAProxy load balancer
4. Gracefully SIGTERMs one kube-apiserver to simulate `/readyz → false` during shutdown
   (ref: [openshift/cluster-kube-apiserver-operator#2222](https://github.com/openshift/cluster-kube-apiserver-operator/pull/2222))
5. Times how long HAProxy takes to mark that backend DOWN
6. Times how long it takes the watch connection to actually die 

## Prerequisites

Run the dependency check to confirm all required tools are present:

```bash
bash deps.sh
```

Required tools: `podman`, `kubectl`, `curl`, `jq`, `bc`, and `kind` at `/usr/local/bin/kind`.

## Step 1 — Generate the live HAProxy config

Before building the container image, the HAProxy config template (`haproxy.cfg`)
must be resolved to a live config with real node IPs. This is done by sourcing
[`common.sh`](common.sh) and calling `generate_live_config`.

> **Note:** `generate_live_config` requires the kind cluster to already be running
> (see [Step 2](#step-2--set-up-the-kind-cluster)). If you are doing a first-time
> setup, complete Step 2 first, then return here.

```bash
source common.sh
generate_live_config
```

What this does:
- Calls `kind get nodes` to enumerate the 3 control-plane node containers
- Runs a single `podman inspect` to retrieve the IP address each node has on the
  `kind` Podman network
- Substitutes the `MASTER0_IP`, `MASTER1_IP`, `MASTER2_IP` placeholders in
  `haproxy.cfg` with the real IPs
- Writes the resolved config to `haproxy-live.cfg` in the current directory
- Populates the global `NODES[]` array used later by `run_drain_test`

## Step 2 — Set up the kind cluster

Source [`common.sh`](common.sh) and call `setup_kind`:

```bash
source common.sh
setup_kind
```

This creates a 3-control-plane kind cluster named `haproxy-cluster` using Podman
as the container runtime. The cluster config is read from
[`cluster-config.yaml`](cluster-config.yaml).

**Architecture note:** On `ppc64le`, the node image is pulled from
`quay.io/powercloud/kind-node:v1.36.5`. On all other architectures it uses
`docker.io/kindest/node:v1.36.5`.

The command waits up to 5 minutes for all nodes to become ready.

## Step 3 — Build the container image

```bash
make build
```

or equivalently:

```bash
podman build -t haproxy-custom:latest -f Containerfile .
```

The [`Containerfile`](Containerfile) builds from
`quay.io/centos/centos:stream10-minimal`, installs HAProxy via `microdnf`, grants
`cap_net_bind_service` for non-root port binding, and copies
`haproxy-live.cfg` (produced in Step 1) into the image at
`/etc/haproxy/haproxy.cfg`. The container runs as the `haproxy` user.

> **Important:** `haproxy-live.cfg` must exist in the current directory before
> running `make build`. Complete Step 1 first.

## Step 4 — Source `common.sh`

All helper functions and shared variables are defined in [`common.sh`](common.sh).
Any script that needs them must source this file:

```bash
source common.sh
```

Key variables exported by `common.sh`:

| Variable | Default | Description |
|---|---|---|
| `HAPROXY_CONTAINER` | `test-haproxy` | Name given to the running HAProxy Podman container |
| `HAPROXY_IMAGE` | `haproxy:1.8-alpine` | HAProxy image (override with the locally built image) |
| `PODMAN_NETWORK` | `kind` | Podman network shared by kind nodes and HAProxy |
| `APISERVER_PORT` | `16443` | Host port HAProxy listens on for kube-apiserver traffic |
| `STATS_PORT` | `19000` | Host port for the HAProxy stats HTTP endpoint |
| `KIND_CLUSTER_NAME` | `haproxy-cluster` | Name of the kind cluster |
| `KUBECONFIG_LB` | `$WORKDIR/kubeconfig-via-lb.yaml` | Kubeconfig pointing at HAProxy instead of kind's own LB |
| `KEEP_CLUSTER` | `0` | Set to `1` to skip teardown after the test completes |

Key functions in `common.sh`:

- **`setup_kind`** — creates the 3-control-plane kind cluster
- **`generate_live_config`** — resolves node IPs and writes `haproxy-live.cfg`
- **`run_drain_test <label>`** — runs one full drain timing test; logs timings for when HAProxy marks the backend DOWN and when the watch connection dies
- **`start_watch <logfile>`** — opens a long-lived `kubectl get pods --watch` in the background
- **`pinned_backend`** — queries the HAProxy stats CSV to find which backend the active watch connection is pinned to
- **`cleanup`** — tears down the HAProxy container and kind cluster (skipped when `KEEP_CLUSTER=1`)

## Step 5 — Run the test

### Complete automated setup

[`setup_test.sh`](setup_test.sh) handles the HAProxy container lifecycle and
builds a kubeconfig that points at HAProxy. Run it after sourcing `common.sh`:

```bash
source common.sh
bash setup_test.sh
```

This script:
1. Removes any existing container named `haproxy` and starts a fresh one, mounting `haproxy.cfg` as a read-only live config
2. Waits (up to 30 s) for all 3 HAProxy backends to report `UP` via the stats endpoint
3. Exports a patched kubeconfig at `$KUBECONFIG_LB` that routes `kubectl` through HAProxy instead of kind's built-in load balancer
4. Runs a sanity `kubectl get nodes` through HAProxy to confirm end-to-end connectivity

### Run the drain test

Once setup is complete, run [`run_down.sh`](run_down.sh):

```bash
bash run_down.sh
```

This calls `generate_live_config` (to refresh node IP data) and then
`run_drain_test "A_with_on_marked_down"`, which:
1. Opens a long-lived `kubectl get pods --watch` through HAProxy
2. Identifies which backend (`master0`, `master1`, or `master2`) the watch is pinned to
3. Sends a graceful `SIGTERM` to the kube-apiserver container on that node
4. Polls the HAProxy stats page until the backend transitions to `DOWN`, recording the elapsed time
5. Polls until the watch process dies, recording the elapsed time

With `on-marked-down shutdown-sessions` active, the watch connection should die
within ~0–1 s of the backend being marked DOWN.

## Teardown

To tear down everything:

```bash
source common.sh
cleanup
```

To leave the cluster and HAProxy running for manual inspection:

```bash
KEEP_CLUSTER=1 bash run_down.sh
```

When `KEEP_CLUSTER=1`, `cleanup` prints the stats URL, kubeconfig path, and the
manual teardown commands instead of destroying the environment.

## HAProxy config overview

The template config (`haproxy.cfg`) runs HAProxy in TCP passthrough mode so the
real kube-apiserver TLS certificates are preserved end-to-end:

- **Frontend** — binds `:16443`, forwards to the `api-server-6443` backend
- **Backend** — round-robin across 3 servers, HTTP health check against `/readyz`,
  `on-marked-down shutdown-sessions` kills existing connections the moment a
  server is marked DOWN
- **Stats** — plain HTTP on `:9000`, used by test scripts to poll backend state

## License

For testing purposes only.
