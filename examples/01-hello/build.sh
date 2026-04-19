#!/usr/bin/env bash
# 编译 hello.p4

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

p4c-bm2-ss --target bmv2 --arch v1model \
    -o hello.json \
    --p4runtime-files hello.p4info.txt \
    hello.p4

echo "Built: hello.json, hello.p4info.txt"
