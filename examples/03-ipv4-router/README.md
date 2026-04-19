# 示例 03 · IPv4 路由器

> 目标：实现一个具备 **LPM 路由 + MAC 改写 + TTL 递减 + 校验和重算** 的完整 IPv4 路由器。

对应教程：几乎覆盖了第 06 ~ 11 章所有内容。

## 拓扑

```text
     10.0.1.0/24                      10.0.2.0/24
  h1 ──────────── port 1  s1  port 2 ──────────── h2
  10.0.1.1                                          10.0.2.2
  MAC 00:00:00:00:01:01        MAC 00:00:00:00:02:02
```

s1 两个端口都要有一个"路由器口"的 MAC：
- port 1 的路由器 MAC: `00:00:00:01:01:01`（h1 把它当网关）
- port 2 的路由器 MAC: `00:00:00:02:02:02`（h2 把它当网关）

每个主机需要有一条默认路由指向对端网络的网关。

## 三张表

1. **`ipv4_lpm`** — 路由表。查目的 IPv4 → `(nextHop, outPort)`
2. **`arp`** — ARP 表。查下一跳 IP → 下一跳 MAC（改 dst mac）
3. **`smac`** — 出端口 → 交换机源 MAC

这三张表对应 Cisco/Juniper 路由器内部的"路由 FIB + ARP 缓存 + 出接口 MAC"。

## 启动

```bash
./build.sh
sudo ./run.sh
```

`run.sh` 会：

1. 建两个 netns `h1`、`h2`，各自配 IP + 默认路由指向网关
2. 起 BMv2，绑两个 veth 到端口 1/2
3. 下发三张表的静态表项
4. `h1 ping h2` 验证

## 核心点

- **TTL 递减**：`hdr.ipv4.ttl = hdr.ipv4.ttl - 1`（在 `set_nhop` 里）
- **MAC 改写顺序**：先 ARP 表找 dst MAC，然后根据 egress_spec 找 src MAC
- **校验和**：ComputeChecksum 里 `update_checksum`，不要自己清零

## 练习

- 加一张 `ttl_check` 表：TTL == 1 时 `send_to_cpu`，模拟 ICMP time-exceeded
- 把 ARP 表换成 P4Runtime 动态填表，实现真正的"ARP 学习"
- 增加一跳中间节点，搭成 h1-s1-s2-h2 的三跳拓扑
