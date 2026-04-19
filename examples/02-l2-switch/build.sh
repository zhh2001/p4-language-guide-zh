#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

p4c-bm2-ss --target bmv2 --arch v1model \
    -o l2_switch.json \
    --p4runtime-files l2_switch.p4info.txt \
    l2_switch.p4

echo "Built: l2_switch.json"
