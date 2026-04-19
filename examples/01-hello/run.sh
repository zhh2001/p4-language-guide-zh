#!/usr/bin/env bash
# 用 veth + network namespace 跑 hello.p4
# 需要 root。清理工作由 trap 自动完成。

set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }

command -v simple_switch >/dev/null \
    || { echo "simple_switch 未找到，请先装 BMv2" >&2; exit 1; }

[[ -f hello.json ]] || ./build.sh

BMV2_PID=""
cleanup() {
    echo "=== cleaning up ==="
    [[ -n "$BMV2_PID" ]] && kill "$BMV2_PID" 2>/dev/null || true
    for ns in h1 h2; do
        ip netns del "$ns" 2>/dev/null || true
    done
    ip link del veth-s1a 2>/dev/null || true
    ip link del veth-s1b 2>/dev/null || true
}
trap cleanup EXIT

echo "=== creating namespaces + veth ==="
ip netns add h1
ip netns add h2

ip link add veth-h1 type veth peer name veth-s1a
ip link add veth-h2 type veth peer name veth-s1b

ip link set veth-h1 netns h1
ip link set veth-h2 netns h2

ip netns exec h1 ip link set lo up
ip netns exec h1 ip link set veth-h1 up
ip netns exec h1 ip addr add 10.0.0.1/24 dev veth-h1

ip netns exec h2 ip link set lo up
ip netns exec h2 ip link set veth-h2 up
ip netns exec h2 ip addr add 10.0.0.2/24 dev veth-h2

for i in veth-s1a veth-s1b; do
    ip link set "$i" up
    ethtool -K "$i" tx off rx off sg off 2>/dev/null || true
done

echo "=== starting BMv2 ==="
simple_switch --log-console --log-level info \
    -i 1@veth-s1a -i 2@veth-s1b \
    hello.json &
BMV2_PID=$!
sleep 1

echo "=== ping test (should NOT succeed, because we reflect) ==="
set +e
ip netns exec h1 ping -W 1 -c 2 10.0.0.2
echo
echo "=== hexdump: h1 should see its own ICMP echoed back ==="
ip netns exec h1 timeout 3 tcpdump -n -c 3 -i veth-h1 icmp || true
set -e

echo
echo "=== done. Press Ctrl+C to stop ==="
wait "$BMV2_PID"
