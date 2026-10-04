#!/usr/bin/env bash
# 创建一个发送端和两个接收端，验证 ECMP。--keep 保留拓扑供手工检查。
set -euo pipefail

keep=0
p4runtime=0
while (( $# )); do
    case "$1" in
        --keep) keep=1 ;;
        --p4runtime) p4runtime=1 ;;
        --help|-h) echo "用法：sudo bash examples/05-ecmp/run.sh [--p4runtime] [--keep]"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
switch_tool=simple_switch
if (( p4runtime )); then switch_tool=simple_switch_grpc; fi
for tool in p4c-bm2-ss "$switch_tool" ip python3 timeout; do
    command -v "$tool" >/dev/null || { echo "缺少命令：$tool" >&2; exit 1; }
done
runtime_python=${P4_ECMP_PYTHON:-python3}
if (( p4runtime )); then
    "$runtime_python" -c 'import grpc; from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc; from p4.config.v1 import p4info_pb2'
else
    command -v simple_switch_CLI >/dev/null || { echo "缺少 simple_switch_CLI" >&2; exit 1; }
fi

thrift_port=${P4_ECMP_THRIFT_PORT:-9090}
grpc_port=${P4_ECMP_GRPC_PORT:-50051}
python3 - "$thrift_port" "$grpc_port" "$p4runtime" <<'PYPORT'
import os
import socket
import sys

if not hasattr(os, "setns"):
    raise SystemExit("需要 Linux Python 3.12+（os.setns）")
try:
    ports = [int(sys.argv[1])]
    if sys.argv[3] == "1":
        ports.append(int(sys.argv[2]))
    if len(set(ports)) != len(ports):
        raise ValueError("Thrift 与 gRPC 端口必须不同")
    for port in ports:
        if not 1 <= port <= 65535:
            raise ValueError("端口必须在 1~65535 之间")
        with socket.socket() as probe:
            probe.bind(("0.0.0.0", port))
except (ValueError, OSError) as error:
    raise SystemExit(f"控制端口不可用：{error}") from error
PYPORT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d /tmp/p4-ecmp.XXXXXX)
suffix=${work_dir##*.}
created_namespaces=()
created_links=()
switch_pid=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$switch_pid" ]]; then
        kill "$switch_pid" 2>/dev/null || true
        wait "$switch_pid" 2>/dev/null || true
    fi
    for link in "${created_links[@]}"; do
        ip link del "$link" 2>/dev/null || true
    done
    for namespace in "${created_namespaces[@]}"; do
        ip netns del "$namespace" 2>/dev/null || true
    done
    if (( status != 0 && status != 130 && status != 143 )); then
        if [[ -f "$work_dir/cli.log" ]]; then
            echo "CLI 输出：" >&2
            cat "$work_dir/cli.log" >&2
        fi
        if [[ -f "$work_dir/switch.log" ]]; then
            echo "BMv2 日志末尾：" >&2
            tail -n 40 "$work_dir/switch.log" >&2
        fi
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 每次编译当前源码，临时产物不会覆盖示例目录中的文件。
bash "$script_dir/build.sh" "$work_dir"

create_host() {
    local number=$1 address=$3 namespace="ecmp-$suffix-$2"
    local switch_if="es$suffix$number" host_if="eh$suffix$number"
    ip netns add "$namespace"
    created_namespaces+=("$namespace")
    ip link add "$switch_if" type veth peer name "$host_if"
    created_links+=("$switch_if")
    ip link set "$host_if" netns "$namespace"
    ip -n "$namespace" link set "$host_if" name eth0
    ip -n "$namespace" link set eth0 address "00:00:00:00:00:0$number"
    ip -n "$namespace" addr add "$address/24" dev eth0
    ip -n "$namespace" link set lo up
    ip -n "$namespace" link set eth0 up
    ip link set "$switch_if" up
}
create_host 1 h1 10.0.1.1
create_host 2 nh1 10.0.2.2
create_host 3 nh2 10.0.2.3
# 网关仅用于 h1 的下一跳选择，交换机不回应 ARP，也没有网关本机协议栈。
ip -n "ecmp-$suffix-h1" route add default via 10.0.1.254 dev eth0
ip -n "ecmp-$suffix-h1" neigh replace 10.0.1.254 lladdr 00:00:00:01:00:00 nud permanent dev eth0

switch_args=(--log-console --log-level info --device-id "$$" --thrift-port "$thrift_port"
    --notifications-addr "ipc://$work_dir/notifications.ipc"
    -i "1@es${suffix}1" -i "2@es${suffix}2" -i "3@es${suffix}3")
control_port=$thrift_port
if (( p4runtime )); then
    control_port=$grpc_port
    simple_switch_grpc "${switch_args[@]}" --no-p4 -- \
        --grpc-server-addr "127.0.0.1:$grpc_port" > "$work_dir/switch.log" 2>&1 &
else
    simple_switch "${switch_args[@]}" "$work_dir/ecmp.json" > "$work_dir/switch.log" 2>&1 &
fi
switch_pid=$!

# 端口预检与启动之间仍可能发生竞争。只连接本进程拥有的监听套接字。
python3 - "$switch_pid" "$control_port" <<'PY'
import os
from pathlib import Path
import socket
import sys
import time

pid, port = map(int, sys.argv[1:])


def owns_listener():
    inodes = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue  # 进程可能刚关闭了该描述符。
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    for family in ("tcp", "tcp6"):
        for line in Path(f"/proc/{pid}/net/{family}").read_text().splitlines()[1:]:
            fields = line.split()
            if (fields[3] == "0A" and fields[9] in inodes
                    and int(fields[1].rsplit(":", 1)[1], 16) == port):
                return True
    return False


deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
        owned = owns_listener()
    except (ProcessLookupError, FileNotFoundError):
        raise SystemExit("FAIL：BMv2 启动失败")
    if not owned:
        time.sleep(0.1)
        continue
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
            break
    except OSError:
        time.sleep(0.1)
else:
    raise SystemExit("FAIL：等待控制服务超时")
PY

if (( p4runtime )); then
    "$runtime_python" "$script_dir/runtime/ctrl.py" \
        --address "127.0.0.1:$grpc_port" --device-id "$$" \
        --p4info "$work_dir/ecmp.p4info.txtpb" --json "$work_dir/ecmp.json" \
        > "$work_dir/cli.log" 2>&1
    cat "$work_dir/cli.log"
else
    # CLI 某些命令失败时仍返回 0。过滤注释、空行，并检查错误文本。
    sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' \
        "$script_dir/runtime/s1-commands.txt" > "$work_dir/commands.txt"
    timeout 10 simple_switch_CLI --thrift-port "$thrift_port" \
        < "$work_dir/commands.txt" > "$work_dir/cli.log" 2>&1
    if grep -Eiq 'Error|Invalid|Exception|Traceback|Unknown (command|syntax)' "$work_dir/cli.log"; then
        echo "FAIL：CLI 配置失败" >&2
        exit 1
    fi
fi
python3 "$script_dir/verify.py" "ecmp-$suffix-h1" "ecmp-$suffix-nh1" "ecmp-$suffix-nh2"
echo "PASS：ECMP 选路、同流稳定性、报头改写和丢弃验证完成"

if (( keep )); then
    echo "拓扑已保留，Ctrl+C 结束并清理。另开终端可执行："
    echo "  sudo ip netns exec ecmp-$suffix-nh1 tcpdump -Q in -n -e -i eth0"
    echo "  sudo ip netns exec ecmp-$suffix-nh2 tcpdump -Q in -n -e -i eth0"
    echo "  sudo python3 $script_dir/verify.py ecmp-$suffix-h1 ecmp-$suffix-nh1 ecmp-$suffix-nh2"
    if (( ! p4runtime )); then
        echo "  simple_switch_CLI --thrift-port $thrift_port"
    fi
    echo "日志：$work_dir/switch.log、$work_dir/cli.log（退出时删除）"
    wait "$switch_pid"
    echo "FAIL：BMv2 已退出" >&2
    exit 1
fi
