#!/usr/bin/env bash
# 创建两主机拓扑，验证报文从原端口反射；--keep 保留拓扑供手工检查。
set -euo pipefail

keep=0
case "${1:-}" in
    --keep) keep=1; shift ;;
    --help|-h) echo "用法：sudo bash examples/01-hello/run.sh [--keep]"; exit 0 ;;
esac
[[ $# -eq 0 ]] || { echo "未知参数；使用 --help 查看用法" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
for tool in p4c-bm2-ss simple_switch ip python3; do
    command -v "$tool" >/dev/null || { echo "缺少命令：$tool" >&2; exit 1; }
done
python3 -c 'import os; assert hasattr(os, "setns"), "需要 Python 3.12+（os.setns）"'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work_dir=$(mktemp -d /tmp/p4-hello.XXXXXX)
suffix=${work_dir##*.}
ns1="hello-$suffix-h1"
ns2="hello-$suffix-h2"
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
    if (( status != 0 && status != 130 && status != 143 )) && [[ -f "$work_dir/switch.log" ]]; then
        echo "BMv2 日志末尾：" >&2
        tail -n 40 "$work_dir/switch.log" >&2
    fi
    rm -rf -- "$work_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 每次编译当前源码，避免复用过期 JSON；临时产物不写入源码目录。
bash "$script_dir/build.sh" "$work_dir"

create_host() {
    local namespace=$1 number=$2
    local switch_if="hs$suffix$number" host_if="hh$suffix$number"
    ip netns add "$namespace"
    created_namespaces+=("$namespace")
    ip link add "$switch_if" type veth peer name "$host_if"
    created_links+=("$switch_if")
    ip link set "$host_if" netns "$namespace"
    ip netns exec "$namespace" ip link set "$host_if" name eth0
    ip netns exec "$namespace" ip link set eth0 address "02:00:00:00:00:0$number"
    ip netns exec "$namespace" ip addr add "10.0.0.$number/24" dev eth0
    ip netns exec "$namespace" ip link set lo up
    ip netns exec "$namespace" ip link set eth0 up
    ip link set "$switch_if" up
}
create_host "$ns1" 1
create_host "$ns2" 2

simple_switch --log-console --log-level info \
    --device-id "$$" --thrift-port 0 \
    --notifications-addr "ipc://$work_dir/notifications.ipc" \
    -i "1@hs${suffix}1" -i "2@hs${suffix}2" "$work_dir/hello.json" \
    > "$work_dir/switch.log" 2>&1 &
switch_pid=$!

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

python3 "$script_dir/verify.py" "$ns1" "$ns2"
echo "PASS：两个端口的 Hello P4 反射验证完成"

if (( keep )); then
    echo "拓扑已保留，Ctrl+C 结束并清理。另开终端可执行："
    echo "  sudo ip netns exec $ns1 tcpdump -Q in -n -e -i eth0 arp"
    echo "  sudo ip netns exec $ns1 ping -c 2 -W 1 10.0.0.2"
    echo "重新验证：sudo python3 $script_dir/verify.py $ns1 $ns2"
    echo "BMv2 日志：$work_dir/switch.log（退出时删除）"
    wait "$switch_pid"
    echo "FAIL：BMv2 已退出" >&2
    exit 1
fi
