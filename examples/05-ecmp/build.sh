#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

p4c-bm2-ss --target bmv2 --arch v1model \
    -o ecmp.json \
    --p4runtime-files ecmp.p4info.txt \
    ecmp.p4

echo "Built: ecmp.json"
