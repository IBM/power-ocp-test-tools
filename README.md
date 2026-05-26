# power-ocp-test-tools
This repository aids the debug of scheduling on ppc64le.

The [`power-ocp-test-tools` project](https://github.com/ibm/power-ocp-test-tools) provides code to test workloads on OpenShift Container Platform (OCP) on a variety of platforms.

## Use

To deploy `quay.io/powercloud/ocp4-power-workload-tools:main` use: 

```
❯ oc apply -k manifests/overlays/multi
...
project.project.openshift.io/openshift-power-workload created
daemonset.apps/ocp4-numa-power-workload created
```

### Use fio debug

```
kustomize build manifests/overlays/fio | oc apply -f -
oc rsh pod/<pod-name>
...
cat << EOF > /tmp/perf.fio
[global]
name=perf-seq-read
time_based
ramp_time=5
runtime=30
readwrite=write
bs=256k
ioengine=libaio
direct=1
numjobs=1
iodepth=32
group_reporting=1

[vd]
filename=/dev/vda
EOF

fio /tmp/perf.fio 
```

## Design

This code is designed to be modular. The code base favors Dockerfile, Ansible, however does accept code in shell and hcl.

## Contributing

If you have any questions or issues you can create a new [issue here][issues].

Pull requests are very welcome! Make sure your patches are well tested.
Ideally create a topic branch for every separate change you make. For
example:

1. Fork the repo
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Added some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

All source files must include a Copyright and License header. The SPDX license header is 
preferred because it can be easily scanned.

If you would like to see the detailed LICENSE click [here](LICENSE).

```text
#
# Copyright 2024 - IBM Corporation. All rights reserved
# SPDX-License-Identifier: Apache-2.0
#
```
