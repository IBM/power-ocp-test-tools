# HAProxy `on-marked-down shutdown-sessions` A/B Test for kube-apiserver

A self-contained one-shot script that reproduces the HAProxy graceful drain behavior discussed in `openshift/cluster-kube-apiserver-operator#2222`.

It stands up a 3-control-plane `kind` cluster, puts a real HAProxy 1.8 in TCP mode in front of the 3 apiservers, opens a long-lived HTTP/2 `kubectl get
pods -A --watch` through it, then SIGTERMs one apiserver to simulate `/readyz -> false` during shutdown. It measures:

1. How long HAProxy takes to mark the backend DOWN via `option httpchk GET /readyz`
2. How long the watch connection actually stays alive after the backend is marked DOWN

The test is run twice for A/B comparison:
* **A** - with `on-marked-down shutdown-sessions`
* **B** - with that option stripped out

## Requirements

* `podman`
* `kind`
* `kubectl`
* `curl`
* `jq`
* `bc`

## Usage

```bash
./test.sh              # full run, tears down at the end
KEEP_CLUSTER=1 ./test.sh   # leave cluster + haproxy running after
```

Environment variables:

* `CLUSTER_NAME` - kind cluster name, default `lbtest`
* `KEEP_CLUSTER=1` - keep the cluster and haproxy container running. Useful for debugging.

With `KEEP_CLUSTER=1` the script leaves:
* `stats page: http://127.0.0.1:19000/`
* `kubeconfig: <workdir>/kubeconfig-via-lb.yaml`
* `workdir` - temp dir with configs and logs

Teardown manually:
```bash
podman rm -f test-haproxy
kind delete cluster --name lbtest
```

## What it does

1. **Create a 3 control-plane kind cluster**
   All 3 apiservers are on the `kind` podman network.

2. **Generate HAProxy config**
   A `haproxy-live.cfg` is embedded in the script and templated with the real node IPs:
   ```haproxy
   backend api-server-6443
       mode tcp
       balance roundrobin
       option httpchk GET /readyz HTTP/1.1\r\nHost:\ localhost
       http-check expect status 200
       default-server inter 5s fall 3 rise 2 check-ssl verify none on-marked-down shutdown-sessions
       server master0 MASTER0_IP:6443 check
       server master1 MASTER1_IP:6443 check
       server master2 MASTER2_IP:6443 check
   ```
   A second copy `haproxy-no-omd.cfg` is created with `on-marked-down shutdown-sessions` removed.

3. **Run HAProxy**
   Container `test-haproxy` is started with the live config, exposing:
   * `127.0.0.1:16443` -> apiserver
   * `127.0.0.1:19000` -> HAProxy stats

   A kubeconfig is rewritten to point at `https://127.0.0.1:16443`.

4. **A/B drain test**
   * Start a long-lived `kubectl ... --watch`
   * Pin which backend the watch landed on via HAProxy stats CSV
   * `crictl stop` the kube-apiserver container on that node with SIGTERM
   * Time `t0` = SIGTERM sent
   * Time `t1` = HAProxy marks backend DOWN
   * Time `t2` = watch process dies

   Run A uses the config with `on-marked-down shutdown-sessions`.
   HAProxy is then reloaded with `podman kill -s HUP` using the no-OMD config and run B is executed.

## Interpreting results

The script logs lines like:

```
RESULT (A_with_on_marked_down): watch connection died +2.34s since SIGTERM, +0.12s since marked DOWN
RESULT (B_without_on_marked_down): watch connection STILL ALIVE 60s after backend marked DOWN
```

With the fix, the watch should die within ~0-1s of the backend being marked DOWN. Without it, the watch stays alive well past the health-check failure,
demonstrating the need for `on-marked-down shutdown-sessions` in TCP mode.

HAProxy stats CSV is used for backend state:
```
curl -s "http://127.0.0.1:19000/;csv"
```

## Notes

* TCP mode passthrough is used so the real apiserver TLS handshake is preserved. Only the server URL in kubeconfig changes.
* The script uses `haproxy:1.8-alpine`, the closest published image to RHEL 8's `1.8.27`.
* `KEEP_CLUSTER=1` is recommended on first run to inspect HAProxy stats and logs.
* The first drain test stops one apiserver. The second test runs with 2 healthy apiservers remaining, which is sufficient for the comparison.

## License

For testing purposes only.
