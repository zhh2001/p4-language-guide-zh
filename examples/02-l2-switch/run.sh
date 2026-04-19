#!/usr/bin/env bash
# 三台主机 + 一个 BMv2 的 L2 交换机实验
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
command -v simple_switch >/dev/null || { echo "需要安装 BMv2" >&2; exit 1; }
command -v simple_switch_CLI >/dev/null || { echo "需要安装 simple_switch_CLI" >&2; exit 1; }

[[ -f l2_switch.json ]] || ./build.sh

BMV2_PID=""
cleanup() {
    echo "=== cleanup ==="
    [[ -n "$BMV2_PID" ]] && kill "$BMV2_PID" 2>/dev/null || true
    for ns in h1 h2 h3; do ip netns del "$ns" 2>/dev/null || true; done
    for i in veth-s1a veth-s1b veth-s1c; do ip link del "$i" 2>/dev/null || true; done
}
trap cleanup EXIT

create_host() {
    local name=$1 ip=$2 mac=$3 hifc=veth-$1 sifc=$4
    ip netns add "$name"
    ip link add "$hifc" type veth peer name "$sifc"
    ip link set "$hifc" netns "$name"
    ip netns exec "$name" ip link set lo up
    ip netns exec "$name" ip link set "$hifc" address "$mac"
    ip netns exec "$name" ip link set "$hifc" up
    ip netns exec "$name" ip addr add "$ip/24" dev "$hifc"
    ip link set "$sifc" up
    ethtool -K "$sifc" tx off rx off sg off 2>/dev/null || true
}

echo "=== topology ==="
create_host h1 10.0.0.1 00:00:00:00:00:01 veth-s1a
create_host h2 10.0.0.2 00:00:00:00:00:02 veth-s1b
create_host h3 10.0.0.3 00:00:00:00:00:03 veth-s1c

echo "=== start BMv2 ==="
simple_switch --log-console --log-level info \
    -i 1@veth-s1a -i 2@veth-s1b -i 3@veth-s1c \
    --thrift-port 9090 \
    l2_switch.json &
BMV2_PID=$!
sleep 1

echo "=== load static table via CLI ==="
simple_switch_CLI --thrift-port 9090 < runtime/s1-commands.txt

echo
echo "=== test: h1 -> h2 ==="
ip netns exec h1 ping -W 1 -c 2 10.0.0.2 || true
echo
echo "=== test: h1 -> h3 ==="
ip netns exec h1 ping -W 1 -c 2 10.0.0.3 || true

echo
echo "=== Ctrl+C to stop ==="
wait "$BMV2_PID"
