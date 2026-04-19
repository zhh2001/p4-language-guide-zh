#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
[[ -f ecmp.json ]] || ./build.sh

BMV2_PID=""
cleanup() {
    echo "=== cleanup ==="
    [[ -n "$BMV2_PID" ]] && kill "$BMV2_PID" 2>/dev/null || true
    for ns in h1 nh1 nh2; do ip netns del "$ns" 2>/dev/null || true; done
    for i in veth-s1a veth-s1b veth-s1c; do ip link del "$i" 2>/dev/null || true; done
}
trap cleanup EXIT

create_host() {
    local name=$1 ip=$2 mac=$3 sifc=$4
    local hifc=veth-$name
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
create_host h1  10.0.1.1 00:00:00:00:00:01 veth-s1a
create_host nh1 10.0.2.2 00:00:00:00:00:02 veth-s1b
create_host nh2 10.0.2.3 00:00:00:00:00:03 veth-s1c

# h1 默认路由走 s1 的 port 1 端网关
ip netns exec h1 ip route add default via 10.0.1.254 dev veth-h1 2>/dev/null || true
ip netns exec h1 ip neigh replace 10.0.1.254 lladdr 00:00:00:01:00:00 dev veth-h1

echo "=== start BMv2 ==="
simple_switch --log-console --log-level info \
    -i 1@veth-s1a -i 2@veth-s1b -i 3@veth-s1c \
    --thrift-port 9090 \
    ecmp.json &
BMV2_PID=$!
sleep 1

simple_switch_CLI --thrift-port 9090 < runtime/s1-commands.txt

echo
echo "=== 产生 500 条流量 (每条不同源端口) ==="
if command -v hping3 >/dev/null; then
    for i in $(seq 10000 10499); do
        ip netns exec h1 hping3 -c 1 -S -p 80 -s "$i" 10.0.2.10 &>/dev/null || true
    done
else
    # fallback: 用 python scapy
    ip netns exec h1 python3 - <<'EOF'
from scapy.all import *
for i in range(10000, 10500):
    p = Ether(src="00:00:00:00:00:01", dst="00:00:00:01:00:00") / \
        IP(src="10.0.1.1", dst="10.0.2.10", ttl=10) / \
        TCP(sport=i, dport=80, flags="S")
    sendp(p, iface="veth-h1", verbose=False)
EOF
fi

echo
echo "=== TX stats on each link ==="
echo -- nh1 --
ip netns exec nh1 cat /sys/class/net/veth-nh1/statistics/rx_packets
echo -- nh2 --
ip netns exec nh2 cat /sys/class/net/veth-nh2/statistics/rx_packets

echo
echo "=== Ctrl+C to stop ==="
wait "$BMV2_PID"
