#!/usr/bin/env bash
# 编译 Hello P4，并在独立的 network namespace 中验证报文反射。
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 sudo bash examples/check-env.sh 运行" >&2; exit 1; }
for tool in p4c-bm2-ss simple_switch ip python3; do
    command -v "$tool" >/dev/null || { echo "缺少命令：$tool" >&2; exit 1; }
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d /tmp/p4-env.XXXXXX)
suffix=${work_dir##*.}
namespace="p4-env-$suffix"
switch_if="p4s$suffix"
host_if="p4h$suffix"
namespace_created=0
link_created=0
switch_pid=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$switch_pid" ]]; then
        kill "$switch_pid" 2>/dev/null || true
        wait "$switch_pid" 2>/dev/null || true
    fi
    if (( link_created )); then
        ip link del "$switch_if" 2>/dev/null || true
    fi
    if (( namespace_created )); then
        ip netns del "$namespace" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -f "$work_dir/switch.log" ]]; then
        echo "BMv2 日志末尾：" >&2
        tail -n 40 "$work_dir/switch.log" >&2
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "编译器：$(command -v p4c-bm2-ss)"
p4c-bm2-ss --version
echo "软件交换机：$(command -v simple_switch)"
simple_switch --version

p4c-bm2-ss --std p4-16 --target bmv2 --arch v1model \
    -o "$work_dir/hello.json" \
    --p4runtime-files "$work_dir/hello.p4info.txtpb" \
    "$script_dir/01-hello/hello.p4"
test -s "$work_dir/hello.json"
test -s "$work_dir/hello.p4info.txtpb"
echo "PASS：Hello P4 编译成功，已生成 BMv2 JSON 和 P4Info"

ip netns add "$namespace"
namespace_created=1
ip link add "$switch_if" type veth peer name "$host_if"
link_created=1
ip link set "$host_if" netns "$namespace"
ip link set "$switch_if" up
ip netns exec "$namespace" ip link set lo up
ip netns exec "$namespace" ip link set "$host_if" up

# 端口 0 让操作系统分配 Thrift 监听端口，避免占用其他实验的 9090。
simple_switch --log-console --log-level info \
    --device-id "$$" --thrift-port 0 \
    --notifications-addr "ipc://$work_dir/notifications.ipc" \
    -i "1@$switch_if" "$work_dir/hello.json" \
    > "$work_dir/switch.log" 2>&1 &
switch_pid=$!

# 等待本进程完成启动，而不是假定固定的 sleep 时间足够。
ready=0
for (( attempt=0; attempt<100; attempt++ )); do
    if ! kill -0 "$switch_pid" 2>/dev/null; then
        echo "FAIL：BMv2 启动失败" >&2
        exit 1
    fi
    if grep -q 'Thrift server was started' "$work_dir/switch.log"; then
        ready=1
        break
    fi
    sleep 0.1
done
if (( ! ready )); then
    echo "FAIL：等待 BMv2 启动超时" >&2
    exit 1
fi

ip netns exec "$namespace" python3 - "$host_if" <<'PY'
import secrets
import socket
import sys
import time

interface = sys.argv[1]
with open(f"/sys/class/net/{interface}/address", encoding="ascii") as f:
    source_mac = bytes.fromhex(f.read().strip().replace(":", ""))

# 广播目的 MAC、实验用 EtherType、随机标识；补齐到 60 字节（不含 FCS）。
frame = (
    b"\xff" * 6 + source_mac + bytes.fromhex("88b5")
    + b"P4-ENV-CHECK:" + secrets.token_bytes(16)
).ljust(60, b"\x00")

with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003)) as rx, \
        socket.socket(socket.AF_PACKET, socket.SOCK_RAW) as tx:
    rx.bind((interface, 0))
    tx.bind((interface, 0))
    tx.send(frame)
    print(f"TX {len(frame)} bytes: {frame.hex()}", flush=True)
    deadline = time.monotonic() + 5
    matched = False
    while time.monotonic() < deadline:
        rx.settimeout(max(0.001, deadline - time.monotonic()))
        try:
            received, address = rx.recvfrom(65535)
        except socket.timeout:
            break
        # 抓包套接字也能看到本机发包；它不能作为交换机反射的证据。
        if address[2] == socket.PACKET_OUTGOING:
            continue
        if received == frame:
            matched = True
            print(f"RX {len(received)} bytes: {received.hex()}")
            print("PASS：接收方向捕获到逐字节一致的反射帧")
            break
    if not matched:
        raise SystemExit("FAIL：未收到一致的反射帧")
PY

echo "PASS：BMv2 报文反射自检完成；退出时清理本次创建的资源"
