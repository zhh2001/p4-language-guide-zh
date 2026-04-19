# 示例 02 · L2 静态转发交换机

> 目标：实现一个最朴素的"按目的 MAC 转发"的 L2 交换机。未知目的 MAC 走广播。

对应教程：[docs/08-匹配动作表.md](../../docs/08-匹配动作表.md)、[docs/11-V1Model架构.md](../../docs/11-V1Model架构.md)。

## 拓扑

```text
 h1 (MAC ..01) ── port 1 ──┐
                           │
 h2 (MAC ..02) ── port 2 ──┤  s1 (l2_switch.p4)
                           │
 h3 (MAC ..03) ── port 3 ──┘
```

三台主机、一个 BMv2 交换机。

## 核心思路

1. `dmac` 表以目的 MAC 做 exact 匹配；每条表项指向一个出端口
2. 未命中时调用 `broadcast(mcast_grp=1)`，控制平面提前把多播组 1 注册成"发往所有其他端口"
3. Egress 阶段 drop 掉 `ingress_port == egress_port` 的副本，避免广播回源

## 启动

```bash
./build.sh
sudo ./run.sh
```

`run.sh` 会：

1. 建 3 个 netns + 对应 veth
2. 启动 BMv2，并通过 `simple_switch_CLI` 下发：
   - `dmac` 表项（h1/h2/h3 的 MAC → port）
   - 多播组 1（端口 1, 2, 3）
3. 运行 `h1 ping h2`、`h1 ping h3` 做验证

## 验证

正常应当：

```text
=== h1 -> h2 ===
64 bytes from 10.0.0.2: ...
=== h1 -> h3 ===
64 bytes from 10.0.0.3: ...
=== broadcast works (arp flood) ===
...
```

## 练习

- 扩展 `dmac` 表加 VLAN 维度：key 加 `vlan.vid : exact`
- 把静态表项换成 **控制平面学习**：Ingress 里 `digest { src_mac, in_port }`，控制脚本监听 digest 消息并把条目写回 `dmac`（真正的 self-learning switch）
- 把 "防止环路" 从 Egress 挪到 broadcast 动作里用 `egress_rid` 过滤
