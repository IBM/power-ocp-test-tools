#!/usr/bin/env bash

set -euo pipefail

need() { command -v "$1" >/dev/null || { echo "missing required tool: $1"; exit 1; }; }

for t in podman kubectl curl jq bc; do need "$t"; done'

echo "check is completed"