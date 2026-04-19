# 12 · 外部对象 Extern

> 本章目标：讲清楚 P4 最"硬件味"的概念——**extern**，以及 V1Model 提供的典型 extern：`counter`、`meter`、`register`、`hash`、`checksum`、`digest`。这是你写出有状态、可统计、可学习的数据平面的钥匙。

## 12.1 为什么需要 extern

P4 语言本身是 **无状态** 的——变量随报文生命周期结束而消失。但真实网络需要：

- 统计某张 ACL 命中过多少次（**counter**）
- 做速率限制（**meter**）
- 记录某个流的 5-tuple 作为 cache（**register**）
- 对 5-tuple 做 ECMP 哈希（**hash**）
- 把 MAC 地址学到控制平面（**digest**）

这些功能显然无法用纯 P4 表达——它们依赖底层芯片/软件的具体实现。于是 P4 引入 `extern`：

> **extern = "由目标提供，P4 只声明接口"的外部对象**

## 12.2 extern 的声明形式

在 `core.p4`、架构描述文件、或你的 P4 程序里，用 `extern` 关键字声明：

```p4
extern Counter {
    Counter(bit<32> size, CounterType type);
    void count(in bit<32> index);
}
```

类似 C++ 的"纯虚类"——只有接口，没有实现。

## 12.3 V1Model 提供的 extern 清单

`v1model.p4` 包含的主要 extern：

| extern | 用途 |
| ------ | ---- |
| `counter`         | 报文数 / 字节数计数 |
| `direct_counter`  | 绑定到某张表的计数器（每个表项一份） |
| `meter`           | 速率限制（token bucket） |
| `direct_meter`    | 表直属 meter |
| `register`        | 有状态可读可写的数组 |
| `hash` / `Hash`   | 通用哈希函数 |
| `checksum16`, `verify_checksum`, `update_checksum` | 校验和 |
| `digest`          | 送一条消息到控制平面（学习用） |
| `clone` / `clone_preserving_field_list` | 报文克隆/镜像 |
| `recirculate` / `resubmit` | 重循环 / 重新提交 |
| `random`          | 随机数 |

下面按使用频率逐个讲。

---

## 12.4 `counter`

### 12.4.1 声明与使用

```p4
counter(1024, CounterType.packets_and_bytes) my_counter;

action count_hit() {
    my_counter.count(meta.flow_id);   // 以 flow_id 为索引累加
}
```

### 12.4.2 参数

- `size`：索引范围 `[0, size-1]`
- `type`：`CounterType.packets` / `CounterType.bytes` / `CounterType.packets_and_bytes`

### 12.4.3 控制平面读取

Counter 的值只能 **控制平面读，数据平面写**。读接口由 P4Runtime 提供，详见 [15 · P4Runtime](./15-P4Runtime控制平面.md)。

### 12.4.4 `direct_counter`

每个表项自动配一份 counter，无需手动管理索引：

```p4
direct_counter(CounterType.packets) per_entry_ctr;

table ipv4_lpm {
    key     = { hdr.ipv4.dst: lpm; }
    actions = { set_nhop; drop; }
    counters = per_entry_ctr;          // 绑定
}
```

---

## 12.5 `meter`

实现 **token bucket**，在数据平面做限速标记。

### 12.5.1 声明

```p4
meter(1024, MeterType.bytes) per_flow_meter;

action police() {
    bit<32> color;
    per_flow_meter.execute_meter(meta.flow_id, color);
    meta.pkt_color = color;   // 0=green, 1=yellow, 2=red
}
```

### 12.5.2 配置

Meter 的速率参数（CIR/PIR/CBS/PBS）由 **控制平面下发**。

### 12.5.3 `direct_meter`

和 direct_counter 类似，每个表项一份 meter：

```p4
direct_meter<bit<32>>(MeterType.bytes) acl_meter;

table acl {
    key = { ... }
    actions = { ... }
    meters  = acl_meter;
}
```

---

## 12.6 `register` —— 真正的状态存储

**最强大的 extern**——一段可读可写的内存数组，寿命超越单个报文。

### 12.6.1 声明

```p4
register<bit<32>>(1024) pkt_count;   // 1024 个 32-bit 槽
```

### 12.6.2 读写

```p4
bit<32> v;
pkt_count.read(v, meta.index);
v = v + 1;
pkt_count.write(meta.index, v);
```

### 12.6.3 典型用途

- **流统计**（每流包数）
- **异常检测**（维护指纹/布隆过滤器）
- **DDoS 缓解**（记录每个源 IP 的包率）
- **简单 NAT** 状态表

### 12.6.4 并发陷阱

BMv2 是 **单线程** 的，所以 read-modify-write 安全。真实硬件可能并发——需要考虑原子性（用 `@atomic` 注解的 action）。

---

## 12.7 `hash`

### 12.7.1 接口

```p4
extern void hash<O, T, D, M>(out O result,
                             in HashAlgorithm algo,
                             in T base,
                             in D data,
                             in M max);
```

### 12.7.2 支持算法（V1Model）

`identity`, `random`, `csum16`, `xor16`, `crc16`, `crc16_custom`, `crc32`, `crc32_custom`

### 12.7.3 使用示例：ECMP 桶选择

```p4
hash(meta.ecmp_hash,
     HashAlgorithm.crc32,
     32w0,                                              // base
     { hdr.ipv4.srcAddr, hdr.ipv4.dstAddr,
       hdr.ipv4.protocol, hdr.tcp.srcPort, hdr.tcp.dstPort },
     32w8);                                             // max（桶数）
```

结果 = `(crc32(data) % max) + base`。

---

## 12.8 `checksum16` / `verify_checksum` / `update_checksum`

V1Model 用的是 **对称的 verify / update** 形式——我们已经在 [09 章](./09-Deparser反解析器.md) 和 [11 章](./11-V1Model架构.md) 看过。简单回顾：

```p4
// 入方向：验证
verify_checksum(cond, data, checksum_field, algo);

// 出方向：重新计算
update_checksum(cond, data, checksum_field, algo);
```

支持的 algo：`csum16` / `crc16` / `crc32` / `xor16`。

VSS 架构则用 `Checksum16` 对象（手动 `.clear()` + `.update()` + `.get()`）——这是规范示例里的样式。

---

## 12.9 `digest` —— 把数据发给控制平面

### 12.9.1 用途

典型场景：**MAC 学习**——数据平面遇到未知源 MAC，把 { src_mac, ingress_port } 打包发给控制平面；控制平面把它插入转发表。

### 12.9.2 接口

```p4
extern void digest<T>(in bit<32> receiver, in T data);
```

- `receiver`：控制平面约定的 session ID
- `data`：要上报的结构

### 12.9.3 示例

```p4
struct mac_learn_t {
    bit<48> src_mac;
    bit<9>  port;
}

action learn() {
    digest<mac_learn_t>(
        1,                                              // receiver id
        { hdr.ethernet.srcAddr, std_meta.ingress_port });
}

table smac_table {
    key     = { hdr.ethernet.srcAddr: exact; }
    actions = { NoAction; learn; }
    default_action = learn;   // 未知源 MAC 就上报
}
```

---

## 12.10 `clone` / `clone_preserving_field_list`

把一份报文副本送到指定 "mirror session"：

```p4
// 在 Ingress 里镜像给 Egress
clone(CloneType.I2E, session_id);

// 带保留元数据
@field_list(1)
struct preserved_meta_t { bit<32> original_in_port; }

clone_preserving_field_list(CloneType.I2E, session_id, 1);
```

- `CloneType.I2E` —— Ingress to Egress
- `CloneType.E2E` —— Egress to Egress
- mirror session 预先由控制平面配置（bmv2 的 `mc_mgrp_create_with_mgid`）

典型用途：抓包上送、INT 遥测、故障诊断。

---

## 12.11 `recirculate` / `resubmit`

### 12.11.1 `recirculate`

在 Egress 结束后，把报文 **再送回 Ingress 重做一遍**：

```p4
recirculate_preserving_field_list(1);
```

典型用途：多层隧道封装解封装（每循环一次剥/加一层）。

### 12.11.2 `resubmit`

在 Ingress 阶段就把报文重新塞回 Ingress 起点（还没进 TM）：

```p4
resubmit_preserving_field_list(1);
```

开销比 recirculate 小。

---

## 12.12 `random`

```p4
bit<16> r;
random(r, 16w0, 16w100);
```

产生 `[0, 100]` 间的均匀随机整数。用于负载采样、故障注入测试。

---

## 12.13 自定义 extern：怎么做？

答：**不能在 P4 里自己实现**。extern 的实现必须由目标（BMv2、Tofino、DPDK 后端等）用 C/C++ 写。

对 BMv2 来说，步骤大致是：

1. 在你的 P4 程序声明 `extern`
2. 在 BMv2 源码里写对应的 C++ 实现（继承 `ExternType`）
3. 重新编译 BMv2
4. 把注册信息加入 `behavioral-model`

详见 BMv2 的 extern 扩展文档——超出本教程范畴。

---

## 12.14 extern 在规范中的语义空位

P4_16 规范 **不定义 extern 的具体语义**——它只是一个接口占位符。

这意味着：

- 同一个 extern 在不同架构里行为可能 **不同**
- 跨架构移植代码时，extern 是最容易踩坑的部分
- 写可移植代码时，**只用** 核心库和标准架构（PSA）定义的 extern

---

## 12.15 一个综合例子：带计数器的 ACL

```p4
/* 声明计数器与 ACL 表 */
direct_counter(CounterType.packets_and_bytes) acl_ctr;

action acl_drop() { mark_to_drop(std_meta); acl_ctr.count(); }
action acl_permit() { acl_ctr.count(); }

table acl {
    key = {
        hdr.ipv4.srcAddr : ternary;
        hdr.ipv4.dstAddr : ternary;
        hdr.ipv4.protocol: exact;
        hdr.tcp.dstPort  : ternary;
    }
    actions  = { acl_drop; acl_permit; NoAction; }
    counters = acl_ctr;
    size     = 512;
    default_action = NoAction;
}
```

之后控制平面不仅能读每条 ACL 命中的次数，还能按字节统计流量。

---

## 12.16 本章小结

- extern = 由目标提供的外部资源，P4 只写接口
- 常用 extern：counter / meter / register / hash / digest / clone
- `counter` 做统计、`meter` 做限速、`register` 做状态、`hash` 做 ECMP
- `digest` 把事件送给控制平面；`clone` 做镜像；`recirculate`/`resubmit` 做重做
- 可移植性风险：不同架构的同名 extern 可能语义不同

## 12.17 下一步

核心语言 + 架构 + extern 都覆盖了。下一章补上一些 **收尾但重要** 的语言特性：注解、静态断言、泛型。[13 · 注解与高级特性](./13-注解与高级特性.md)。
