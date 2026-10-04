#!/usr/bin/env bash
set -euo pipefail
[[ $# -le 1 ]] || { echo "用法：bash build.sh [输出目录]" >&2; exit 2; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=${1:-$script_dir}
mkdir -p -- "$output_dir"

p4c-bm2-ss --std p4-16 --target bmv2 --arch v1model \
    -o "$output_dir/acl.json" \
    --p4runtime-files "$output_dir/acl.p4info.txtpb" \
    "$script_dir/acl.p4"

echo "已生成：$output_dir/acl.json、$output_dir/acl.p4info.txtpb"
