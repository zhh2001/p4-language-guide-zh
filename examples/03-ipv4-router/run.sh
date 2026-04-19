#!/usr/bin/env bash
# 两台主机 + 一个 BMv2 路由器，跨网段 ping
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
command -v simple_switch >/dev/null || { echo "需要安装 BMv2" >&2; exit 1; }

[[ -f router.json ]] || ./build.sh

BMV2_PID=""
cleanup() {
    echo "=== cleanup ==="
    [[ -n "$BMV2_PID" ]] && kill "$BMV2_PID" 2>/dev/null || true
    for ns in h1 h2; do ip netns del "$ns" 2>/dev/null || true; done
    for i in veth-s1a veth-s1b; do ip link del "$i" 2>/dev/null || true; done
}
trap cleanup EXIT

# 主机：IP + 默认路由 + 静态 ARP (避免 h1 去 ARP 网关)
create_host() {
    local name=$1 ip=$2 mac=$3 gw=$4 gw_mac=$5 sifc=$6
    local hifc=veth-$name
    ip netns add "$name"
    ip link add "$hifc" type veth peer name "$sifc"
    ip link set "$hifc" netns "$name"
    ip netns exec "$name" ip link set lo up
    ip netns exec "$name" ip link set "$hifc" address "$mac"
    ip netns exec "$name" ip link set "$hifc" up
    ip netns exec "$name" ip addr add "$ip/24" dev "$hifc"
    ip netns exec "$name" ip route add default via "$gw" dev "$hifc"
    ip netns exec "$name" ip neigh replace "$gw" lladdr "$gw_mac" dev "$hifc"
    ip link set "$sifc" up
    ethtool -K "$sifc" tx off rx off sg off 2>/dev/null || true
}

echo "=== topology ==="
create_host h1 10.0.1.1 00:00:00:00:01:01 10.0.1.254 00:00:00:01:01:01 veth-s1a
create_host h2 10.0.2.2 00:00:00:00:02:02 10.0.2.254 00:00:00:02:02:02 veth-s1b

# h2 需要路由 10.0.1.0/24 回程（默认路由已覆盖）
# 在 arp 表里记录 h1 / h2 的实际 MAC (用于回程时改 dst mac)
# 其实 arp 表的键是 next hop IP=目的端主机的 IP；见 runtime/s1-commands.txt

echo "=== start BMv2 ==="
simple_switch --log-console --log-level info \
    -i 1@veth-s1a -i 2@veth-s1b \
    --thrift-port 9090 \
    router.json &
BMV2_PID=$!
sleep 1

echo "=== load tables ==="
simple_switch_CLI --thrift-port 9090 < runtime/s1-commands.txt

echo
echo "=== test: h1 -> h2 across subnets ==="
ip netns exec h1 ping -W 1 -c 3 10.0.2.2 || true

echo
echo "=== test: h2 -> h1 ==="
ip netns exec h2 ping -W 1 -c 3 10.0.1.1 || true

echo
echo "=== Ctrl+C to stop ==="
wait "$BMV2_PID"
