#!/bin/sh

podman build -f Containerfile -t local/mockserver --platform linux/ppc64le .