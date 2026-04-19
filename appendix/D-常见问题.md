# 附录 D · 常见问题与调试技巧

> 按症状索引。遇到 bug 先在这里翻——大多数新手坑都在里面。

## D.1 编译期

### D.1.1 `Could not find architecture file 'v1model.p4'`

**原因**：p4c 没找到 `v1model.p4`。

**排查**：

```bash
dpkg -L p4lang-p4c | grep v1model   # apt 装的
ls /usr/local/share/p4c/p4include/  # 源码装的
```

**解决**：

```bash
p4c-bm2-ss -I/usr/local/share/p4c/p4include ...
```

### D.1.2 `error: No match for call to function 'verify'`

**常见原因**：`verify` 写在了 `control` 里。`verify` 仅限 parser。

**解决**：control 里用 `if + drop`。

### D.1.3 `error: 'xxx' is not a left-value`

**含义**：`out`/`inout` 参数传入了不能被赋值的表达式。

```p4
f(y = 0);          // ❌
f(y = my_var);     // ✅
```

### D.1.4 表项键的位宽不匹配

```text
error: Table key width must match the value provided
```

通常是 P4Runtime 下发时 byte 数不对。举例：`bit<9>` 的字段应该用 **2 字节**（向上取整）big-endian：

```python
m.exact.value = bytes([0, 1])   # 对应端口 1
```

### D.1.5 表不能超过 N 个 action

硬件表限制。仅 TNA / 真实 ASIC 会遇到，BMv2 不会。

## D.2 运行期（BMv2）

### D.2.1 发包但 BMv2 不处理

**典型原因**：

- **TX 卸载没关**：`ethtool -K vethX tx off rx off`
- 接口没 up：`ip link set vethX up`
- 绑定错了：`-i 1@vethX`，端口号不能从 0 开始（BMv2 要求 ≥ 1）

### D.2.2 `set_metadata` 日志显示 `egress_spec=511`

表明报文被丢弃了。回溯：

- 是不是命中了 `mark_to_drop` 动作？
- `default_action` 是不是 `drop`？
- 某段 `if` 分支把 egress_spec 清掉了？

### D.2.3 `table_add` 报 "table not found"

表名要用 **完全限定名**，比如 `MyIngress.ipv4_lpm`，不是 `ipv4_lpm`。

先看清楚有哪些表：

```
$ simple_switch_CLI --thrift-port 9090
RuntimeCmd: show_tables
```

### D.2.4 IPv4 校验和出错（收方丢弃）

90% 是 **忘了 ComputeChecksum**。或者忘了把 `hdr.ipv4.hdrChecksum` 字段清零再重算。

**正确写法**：

```p4
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}
```

`update_checksum` 会自动把 `hdrChecksum` 置零再重算——不要手动 `= 0`。

### D.2.5 VLAN 没出现在线上

检查：Ingress 里是否调用了 `hdr.vlan.setValid()`。
`emit` 只输出 valid 的 header——忘 setValid 会被默默跳过。

### D.2.6 报文只走一次就消失

看是不是 `egress_spec == ingress_port` 导致被 BMv2 丢弃。BMv2 默认 **会丢掉出端口等于入端口的包**（"split horizon"）。

**解决**：

- 如果是刻意反射，用 `recirculate()`
- 或启动时加 `--no-loopback-check`

## D.3 P4Runtime

### D.3.1 `FAILED_PRECONDITION: not primary`

当前 election_id 不是最大。升高后再试：

```python
ELECTION_ID = p4runtime_pb2.Uint128(high=0, low=1000)
```

### D.3.2 `INVALID_ARGUMENT: match field type mismatch`

LPM 字段要用 `m.lpm`，不是 `m.exact`。
Ternary 字段要 `m.ternary.value` 和 `m.ternary.mask`。

### D.3.3 `packet_in` 收不到

**检查**：

1. Egress 里是否 `if (egress_port == CPU_PORT) { hdr.packet_in.setValid(); }`
2. `@controller_header("packet_in")` 是否写了
3. 启动 BMv2 时是否指定了 `--cpu-port`

## D.4 调试技巧

### D.4.1 打开 BMv2 trace 日志

```bash
simple_switch --log-console --log-level trace
```

日志会显示每个 header 的 extract 位置、每张表的查找结果、每个 action 的执行——堪比黑盒调试的"断点"。

### D.4.2 抓包对比

```bash
sudo tcpdump -ni s1-eth1 -w in.pcap
sudo tcpdump -ni s1-eth2 -w out.pcap
```

然后用 Wireshark 打开两个 pcap 对比，能一眼看出头是否被改、checksum 对不对。

### D.4.3 用 `scapy` 手工造包

```python
from scapy.all import *

p = Ether(src='00:00:00:00:00:01', dst='00:00:00:00:00:02') / \
    IP(src='10.0.0.1', dst='10.0.2.3') / \
    TCP(sport=1234, dport=80)

sendp(p, iface='h1-eth0', count=5)
```

比起依赖 `ping`，`scapy` 能精确控制每一个字段。

### D.4.4 精确诊断 "包进来但没出去"

BMv2 日志里的关键行：

```
Recirculating packet
Adding to queue
Pipeline 'ingress': done
Pipeline 'egress':  done
sending out packet on port N
```

缺哪一行就在哪一段卡住了。

### D.4.5 p4c 的 `--dump` 选项

```bash
p4c-bm2-ss --dump-dir /tmp/dump my.p4
```

把中间表示（IR）全 dump 出来。进阶调试或写 backend 时很有用。

## D.5 常见"看起来对但其实错"的写法

### D.5.1 赋值一个未 setValid 的 header

```p4
Ethernet_h eth;
eth.dstAddr = 0;    // ⚠️ 合法，但 eth.isValid() 仍是 false
```

之后 `emit(eth)` 什么也不会写出。

### D.5.2 用 `==` 比较无方向 header 与 valid header

```p4
if (hdr.ipv4 == hdr.ipv4_backup) { ... }
```

相等条件之一：**有效位相同**。注意不要和"字段相等"混为一谈。

### D.5.3 hash 的 max 没写够

```p4
hash(out, algo, 32w0, data, 32w10);   // 出值 [0, 9]
```

如果后面用这个 10 去查一张 1024 槽的表，会严重偏斜（仅用前 10 槽）。

### D.5.4 表的 key 字段顺序

```p4
key = {
    hdr.ipv4.src : exact;
    hdr.ipv4.dst : exact;
}
```

控制平面下发时 **必须按同样顺序** 给出字段——错了会被拒绝。

## D.6 问完这里还不行？

1. 用 **最小化复现** 做一个 `.p4` + `.txt` + `.pcap`，发到 [本仓库 Issues](../../issues)
2. 或 [P4 community mailing list](https://lists.p4.org/)
3. 英语好的话直接开 [p4lang/p4c](https://github.com/p4lang/p4c/issues) —— 官方维护者会回

## D.7 一些"显然但容易忘"的黄金法则

- **新增 header 要 `setValid()`，删除要 `setInvalid()`**
- **Deparser 里只 `emit`，不写业务**
- **ComputeChecksum 放在 Deparser 之前**
- **控制平面改变后，BMv2 不会自动热加载——需要重启或用 P4Runtime**
- **`bit<9>` 一个字段在 P4Runtime 里是 2 字节，不是 9 bits**
- **`simple_switch` 端口号从 **1** 开始，不是 0**
