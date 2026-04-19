#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

p4c-bm2-ss --target bmv2 --arch v1model \
    -o acl.json \
    --p4runtime-files acl.p4info.txt \
    acl.p4

echo "Built: acl.json"
