#!/usr/bin/env bash
# 创建三主机拓扑，验证静态单播与泛洪。--keep 保留拓扑供手工检查。
set -euo pipefail

keep=0
case "${1:-}" in
    --keep) keep=1; shift ;;
    --help|-h) echo "用法：sudo bash examples/02-l2-switch/run.sh [--keep]"; exit 0 ;;
esac
[[ $# -eq 0 ]] || { echo "未知参数。使用 --help 查看用法" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
for tool in p4c-bm2-ss simple_switch simple_switch_CLI ip ping python3 timeout; do
    command -v "$tool" >/dev/null || { echo "缺少命令：$tool" >&2; exit 1; }
done

thrift_port=${P4_L2_THRIFT_PORT:-9090}
python3 - "$thrift_port" <<'PY'
import os
import socket
import sys

if not hasattr(os, "setns"):
    raise SystemExit("需要 Linux Python 3.12+（os.setns）")
try:
    port = int(sys.argv[1])
    if not 1 <= port <= 65535:
        raise ValueError("端口必须在 1~65535 之间")
    with socket.socket() as probe:
        probe.bind(("0.0.0.0", port))
except (ValueError, OSError) as error:
    raise SystemExit(f"Thrift 端口不可用：{error}") from error
PY

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d /tmp/p4-l2.XXXXXX)
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
    local number=$1 namespace="l2-$suffix-h$1"
    local switch_if="ls$suffix$number" host_if="lh$suffix$number"
    ip netns add "$namespace"
    created_namespaces+=("$namespace")
    ip link add "$switch_if" type veth peer name "$host_if"
    created_links+=("$switch_if")
    ip link set "$host_if" netns "$namespace"
    ip -n "$namespace" link set "$host_if" name eth0
    ip -n "$namespace" link set eth0 address "00:00:00:00:00:0$number"
    ip -n "$namespace" addr add "10.0.0.$number/24" dev eth0
    ip -n "$namespace" link set lo up
    ip -n "$namespace" link set eth0 up
    ip link set "$switch_if" up
}
for number in 1 2 3; do create_host "$number"; done

simple_switch --log-console --log-level info \
    --device-id "$$" --thrift-port "$thrift_port" \
    --notifications-addr "ipc://$work_dir/notifications.ipc" \
    -i "1@ls${suffix}1" -i "2@ls${suffix}2" -i "3@ls${suffix}3" \
    "$work_dir/l2_switch.json" > "$work_dir/switch.log" 2>&1 &
switch_pid=$!

# 端口预检与启动之间仍可能发生竞争。只连接本进程拥有的监听套接字。
python3 - "$switch_pid" "$thrift_port" <<'PY'
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
    raise SystemExit("FAIL：等待 Thrift 服务超时")
PY

# CLI 对某些命令错误仍返回 0，因此也要检查错误文本，再验证数据平面。
# 本机 CLI 不识别 # 注释。空行还会重复上一条命令，必须先过滤。
sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' \
    "$script_dir/runtime/s1-commands.txt" > "$work_dir/commands.txt"
timeout 10 simple_switch_CLI --thrift-port "$thrift_port" \
    < "$work_dir/commands.txt" > "$work_dir/cli.log" 2>&1
if grep -Eiq 'Error|Invalid|Exception|Traceback|Unknown (command|syntax)' "$work_dir/cli.log"; then
    echo "FAIL：CLI 配置失败" >&2
    exit 1
fi

python3 "$script_dir/verify.py" "${created_namespaces[@]}"
for pair in '1 2' '2 3' '3 1'; do
    read -r source destination <<< "$pair"
    ip netns exec "l2-$suffix-h$source" ping -n -W 1 -c 2 "10.0.0.$destination"
done
echo "PASS：L2 单播、泛洪、回源抑制和三对主机 ping 验证完成"

if (( keep )); then
    echo "拓扑已保留，Ctrl+C 结束并清理。另开终端可执行："
    echo "  sudo ip netns exec l2-$suffix-h1 tcpdump -Q in -n -e -i eth0"
    echo "  sudo ip netns exec l2-$suffix-h1 ping -c 2 -W 1 10.0.0.2"
    echo "  simple_switch_CLI --thrift-port $thrift_port"
    echo "重新验证：sudo python3 $script_dir/verify.py ${created_namespaces[*]}"
    echo "日志：$work_dir/switch.log、$work_dir/cli.log（退出时删除）"
    wait "$switch_pid"
    echo "FAIL：BMv2 已退出" >&2
    exit 1
fi
