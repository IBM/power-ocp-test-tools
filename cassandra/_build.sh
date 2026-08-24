#!/bin/sh

# Add --no-cache When Testing
podman build --log-level=debug --security-opt seccomp=unconfined --no-cache -f Containerfile -t local/cassandra --platform linux/ppc64le .