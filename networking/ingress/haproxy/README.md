# HAProxy `on-marked-down shutdown-sessions` Kube-apiserver

1. creates 3-control-plane kind cluster, puts a real
2. loads Podman Container in haproxy.cfg (embedded below) in front of the 3 apiservers
3. opens a long-lived HTTP/2 watch through it
4. gracefully SIGTERMs one apiserver to simulate /readyz -> false during shutdown
  - Ref the scenario in openshift/cluster-kube-apiserver-operator#2222)
  - times how long it takes haproxy to mark that backend DOWN
  - times how long it takes the watch connection to actually die
5. re-runs the same test with `on-marked-down shutdown-sessions` excluded

```
$ bash deps.sh

```



## License

For testing purposes only.
