# 示例 05 · ECMP 等价多路径

> 目标：实现一个真正"线速分流"的 ECMP 算法。对每条流做 CRC32 哈希，稳定选择 N 条等价链路中的一条。

对应教程：[docs/11-V1Model架构.md](../../docs/11-V1Model架构.md)、[docs/12-外部对象Extern.md](../../docs/12-外部对象Extern.md)（`hash`）。

## 拓扑

```text
            ┌──── port 2 ──── nh1 ────┐
 h1 ─ port 1 s1                         (到 10.0.2.0/24)
            └──── port 3 ──── nh2 ────┘
```

s1 到目的网段有两条等价出口；我们希望：

- 同一条 **TCP/UDP 流**（相同 5-tuple）始终走同一条路径 —— 避免报文乱序
- 不同流 **均匀分布** —— 发挥双链路带宽

## 关键设计：两张表

1. `ipv4_lpm` ：目的 IP → **(group_id, group_size)**。在 action 里计算 `hash(5-tuple) % group_size` 作为组内索引。
2. `ecmp_group_to_nh` ：(group_id, hash_index) → 具体下一跳的 (dst MAC, src MAC, out port)。

控制平面配置示例（两个出口）：

```text
# 1 个 LPM 表项 + 2 个组内表项
table_add MyIngress.ipv4_lpm MyIngress.set_ecmp_group 10.0.2.0/24 => 1 2
table_add MyIngress.ecmp_group_to_nh MyIngress.set_nh 1 0 => 00:00:00:00:00:02 00:00:00:01:00:01 2
table_add MyIngress.ecmp_group_to_nh MyIngress.set_nh 1 1 => 00:00:00:00:00:03 00:00:00:01:00:02 3
```

为什么是 `0` 和 `1`？因为 `hash(...)` 的 `max = group_size = 2`，所以结果只会是 `0` 或 `1`。

## 构建 + 运行

```bash
./build.sh
sudo ./run.sh
```

脚本会：

1. 创建 h1（10.0.1.1）以及模拟两个下一跳设备 nh1 / nh2（在 10.0.2.0/24 网段）
2. 下发表项
3. 用 `hping3` 发几百条不同源端口的 TCP，观察两条链路 TX 字节数，验证分流

## 验证脚本关键命令

```bash
# 发 500 个不同源端口的 TCP SYN
for i in $(seq 10000 10500); do
    ip netns exec h1 hping3 -c 1 -S -p 80 -s $i 10.0.2.10 &> /dev/null
done

# 查看两条出口的 TX 统计
ip netns exec nh1 cat /proc/net/dev | grep veth-nh1
ip netns exec nh2 cat /proc/net/dev | grep veth-nh2
```

理想状态下两条链路收到的包数应该接近 1:1。

## Python 版本的 P4Runtime 控制平面

如果你想用 P4Runtime（而不是 Thrift CLI）下发表项，参考 [runtime/ctrl.py](./runtime/ctrl.py)。

## 练习

- 把 ECMP 扩到 4 路：只需改 `group_size = 4` + 加两条 `ecmp_group_to_nh`
- 用 `action_profile` + `action_selector`（V1Model 扩展）代替手写的两张表。这是真实硬件更高效的做法
- 加入 **一致性哈希**：链路 flap 时尽量不改已建立流的落点（需要配合 register 记录流状态）
