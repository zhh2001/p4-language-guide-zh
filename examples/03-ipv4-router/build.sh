#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

p4c-bm2-ss --target bmv2 --arch v1model \
    -o router.json \
    --p4runtime-files router.p4info.txt \
    router.p4

echo "Built: router.json"
