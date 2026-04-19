# 11 · V1Model 架构详解

> 本章目标：讲清楚 **V1Model** 这个你在 BMv2 上做实验几乎一定要用到的架构——六大块是什么、每块拿到什么参数、`standard_metadata` 的每一个关键字段、克隆/重新注入等高级机制怎么玩。

## 11.1 V1Model 概览

V1Model 是 BMv2 `simple_switch` 使用的架构。流水线是**经典的 Ingress + Egress 两阶段**：

```text
                     ingress_port         egress_spec      egress_port
                        │                    │                │
                        ▼                    ▼                ▼
Packet ─► Parser ─► VerifyChk ─► Ingress ─► [TM] ─► Egress ─► ComputeChk ─► Deparser ─► Packet
              │                    ▲  │                ▲                                    ▲
              └─► parser_error ────┘  │                │                                    │
                                      │            Traffic Manager                       recirculate?
                                      │         (drop / mcast / queue)
                                      └──────────────────────────────────────────────────── clone?
```

六个 **可编程** 块（白色）：

| # | 块 | 职责 |
| - | --- | ---- |
| 1 | Parser                  | 解析报头 |
| 2 | VerifyChecksum (简写 VC) | 校验入方向 checksum |
| 3 | Ingress                 | 查表、选路由、设 egress |
| 4 | Egress                  | 出方向处理（可选） |
| 5 | ComputeChecksum (CC)     | 重新计算出方向 checksum |
| 6 | Deparser                | 把 headers 写回字节流 |

黑盒：**Traffic Manager**（TM），架构提供，不可编程。负责队列、多播、drop、重新注入。

## 11.2 顶层 package

`v1model.p4` 里的 `V1Switch` 定义：

```p4
package V1Switch<H, M>(Parser<H, M>           p,
                      VerifyChecksum<H, M>   vr,
                      Ingress<H, M>          ig,
                      Egress<H, M>           eg,
                      ComputeChecksum<H, M>  ck,
                      Deparser<H>            dep);
```

**六个参数必须一次全填**，不能省略：

```p4
V1Switch(MyParser(),
         MyVerifyChecksum(),
         MyIngress(),
         MyEgress(),
         MyComputeChecksum(),
         MyDeparser()) main;
```

## 11.3 六个块的签名

### 11.3.1 Parser

```p4
parser Parser<H, M>(packet_in                b,
                   out H                     parsedHdr,
                   inout M                   meta,
                   inout standard_metadata_t stdMeta);
```

- `b`：入站报文
- `parsedHdr`：你定义的所有 headers 结构体（**out** —— parser 写）
- `meta`：用户元数据（**inout** —— parser 可读写）
- `stdMeta`：标准元数据

### 11.3.2 VerifyChecksum

```p4
control VerifyChecksum<H, M>(inout H hdr, inout M meta);
```

典型实现：

```p4
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, ..., hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}
```

### 11.3.3 Ingress

```p4
control Ingress<H, M>(inout H hdr,
                     inout M meta,
                     inout standard_metadata_t stdMeta);
```

这是你花 80% 时间的地方——查表、设出端口、改包头。

### 11.3.4 Egress

```p4
control Egress<H, M>(inout H hdr,
                    inout M meta,
                    inout standard_metadata_t stdMeta);
```

主要用途：

- 出方向包头修改（push VLAN、改 MAC）
- 镜像 / 克隆后的特殊处理
- 出方向 QoS 标记

### 11.3.5 ComputeChecksum

```p4
control ComputeChecksum<H, M>(inout H hdr, inout M meta);
```

和 VerifyChecksum 对称，但这里是**重新计算**：

```p4
apply {
    update_checksum(
        hdr.ipv4.isValid(),
        { hdr.ipv4.version, ..., hdr.ipv4.dstAddr },
        hdr.ipv4.hdrChecksum,
        HashAlgorithm.csum16);
}
```

### 11.3.6 Deparser

```p4
control Deparser<H>(packet_out b, in H hdr);
```

注意：**Deparser 没有 metadata 参数**——元数据只存在于流水线内部，不会上线。

## 11.4 `standard_metadata_t` 速查表

`v1model.p4` 里的定义（简化版）：

```p4
struct standard_metadata_t {
    bit<9>   ingress_port;       // 入端口
    bit<9>   egress_spec;        // 要把包送到的端口（Ingress 里写）
    bit<9>   egress_port;        // Egress 阶段的实际端口（只读）
    bit<32>  instance_type;      // 实例类型（正常 / 克隆 / 重循环…）
    bit<32>  packet_length;      // 入包字节数

    // 时间戳
    bit<32>  enq_timestamp;      // 进队列时间（us）
    bit<19>  enq_qdepth;         // 进队列时深度
    bit<32>  deq_timedelta;      // 在队列中逗留时间（ns）
    bit<19>  deq_qdepth;         // 离队列时深度
    bit<48>  ingress_global_timestamp;
    bit<48>  egress_global_timestamp;

    // 多播
    bit<16>  mcast_grp;
    bit<16>  egress_rid;         // replication id
    bit<32>  lf_field_list;      // learning 相关

    // 校验 / parser
    bit<1>   checksum_error;
    error    parser_error;
    bit<3>   priority;           // 队列优先级
}
```

### 11.4.1 最常用的 5 个字段

| 字段 | 读/写 | 说明 |
| ---- | ---- | ---- |
| `ingress_port` | 读 | 入端口；用在 ACL 的 key、SLA 统计 |
| `egress_spec` | 写 | Ingress 里写它 = 决定报文去哪 |
| `egress_port` | 读 | 到 Egress 阶段能看到真正的出端口 |
| `parser_error` | 读 | parser 里 `verify` 失败时填入的错误 |
| `packet_length` | 读 | 入包字节数（不含 CRC） |

### 11.4.2 特殊值

- `egress_spec = 511` → drop（也可以用 `mark_to_drop(std_meta)`）
- `mcast_grp > 0`  → 启用多播（端口由控制平面配置的 multicast group 决定）

## 11.5 V1Model 内置 action 与 extern

除了 `core.p4` 提供的 `NoAction`，V1Model 还提供：

### 11.5.1 `mark_to_drop(std_meta)`

```p4
action mark_to_drop(inout standard_metadata_t smeta) {
    smeta.egress_spec = 511;
    smeta.mcast_grp   = 0;
}
```

**比直接写 `std_meta.egress_spec = 511` 更清晰**。

### 11.5.2 `verify_checksum` / `update_checksum`

签名：

```p4
extern void verify_checksum<T, O>(in bool cond, in T data, inout O checksum, HashAlgorithm algo);
extern void update_checksum<T, O>(in bool cond, in T data, inout O checksum, HashAlgorithm algo);
```

- `cond = false` 时什么都不做
- `data` 是一个 struct / tuple，包含所有参与计算的字段
- `algo` 支持 `csum16`, `crc16`, `crc32`, `xor16` 等

### 11.5.3 `hash`

```p4
extern void hash<O, T, D, M>(out O result,
                             in HashAlgorithm algo,
                             in T base,
                             in D data,
                             in M max);
```

在 ECMP / 流 ID 生成里很常用：

```p4
hash(meta.flow_id,
     HashAlgorithm.crc32,
     32w0,
     { hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.ipv4.protocol,
       hdr.tcp.srcPort, hdr.tcp.dstPort },
     32w1024);
```

### 11.5.4 `random`

```p4
extern void random<T>(out T result, in T lo, in T hi);
```

### 11.5.5 `clone` / `clone_preserving_field_list`

拷贝一份报文送到指定 session：

```p4
clone(CloneType.I2E, session_id);
```

- `I2E` = Ingress 拷到 Egress
- `E2E` = Egress 再拷一份
- session 由控制平面用 `bm_mc` 接口预配

### 11.5.6 `digest`

把数据发送给控制平面（学习用）：

```p4
digest<learn_t>(LEARN_RECEIVER, { hdr.ethernet.srcAddr, std_meta.ingress_port });
```

### 11.5.7 `recirculate` / `resubmit`

- `recirculate()`：把包从 Egress 的尾巴重新塞回 Ingress
- `resubmit()`：在 Ingress 阶段就重新做一遍（不出 TM）

需要传"要保留的元数据字段列表"。

## 11.6 `instance_type` 值表

| 值 | 含义 |
| -- | ---- |
| 0 | 正常包（从端口进来） |
| 1 | Ingress 克隆（I2E） |
| 2 | Egress 克隆（E2E） |
| 3 | 由 `recirculate` 产生 |
| 4 | 由 `resubmit` 产生 |
| 5 | 由 replication（多播）产生 |

用这个字段可以判断一个包是不是"特殊来源"：

```p4
if (std_meta.instance_type == 1) {
    // 这个包是 Ingress 克隆出来的（镜像流量），可能要走特殊逻辑
}
```

## 11.7 一份完整的骨架

```p4
#include <core.p4>
#include <v1model.p4>

/* ===== 类型 ===== */
header ethernet_t { bit<48> dst; bit<48> src; bit<16> etherType; }
header ipv4_t     { /* ... 略 ... */ }

struct headers   { ethernet_t ethernet; ipv4_t ipv4; }
struct metadata  { bit<32> nextHop; }

/* ===== Parser ===== */
parser MyParser(packet_in p, out headers hdr, inout metadata meta, inout standard_metadata_t s) {
    state start {
        p.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        p.extract(hdr.ipv4);
        transition accept;
    }
}

/* ===== VerifyChecksum ===== */
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/* ===== Ingress ===== */
control MyIngress(inout headers hdr, inout metadata meta, inout standard_metadata_t s) {
    action drop() { mark_to_drop(s); }

    action set_nhop(bit<32> nh, bit<9> port) {
        meta.nextHop   = nh;
        s.egress_spec  = port;
        hdr.ipv4.ttl   = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key     = { hdr.ipv4.dstAddr: lpm; }
        actions = { set_nhop; drop; NoAction; }
        size           = 2048;
        default_action = drop;
    }

    apply {
        if (hdr.ipv4.isValid()) ipv4_lpm.apply();
    }
}

/* ===== Egress ===== */
control MyEgress(inout headers hdr, inout metadata meta, inout standard_metadata_t s) {
    apply { }
}

/* ===== ComputeChecksum ===== */
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

/* ===== Deparser ===== */
control MyDeparser(packet_out p, in headers hdr) {
    apply {
        p.emit(hdr.ethernet);
        p.emit(hdr.ipv4);
    }
}

/* ===== 顶层 ===== */
V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(),
         MyEgress(), MyComputeChecksum(), MyDeparser()) main;
```

这是一个典型的 **IPv4 路由器** 骨架。实际代码见 [examples/03-ipv4-router](../examples/03-ipv4-router)。

## 11.8 V1Model 的限制

- 只有 **一个 ingress + 一个 egress**——不能自己加阶段
- 校验和字段必须是单独的 `bit<16>` 字段
- 没有 `PacketOut` header（和 PSA 不同）
- `simple_switch` 默认最多 256 端口、`bit<9>` 端口号

## 11.9 本章小结

- V1Model = BMv2 的默认架构，学习和教学几乎必用
- 六个可编程块：**Parser + VC + Ingress + Egress + CC + Deparser**
- `standard_metadata` 是你和架构沟通的仪表盘
- 五大常用操作：drop、检查 ttl、查表转发、校验和、clone/digest
- 限制要知道，以后迁移 PSA 或 TNA 更顺利

## 11.10 下一步

六大块都能写了。但还差一块 P4 的真正杀手锏——**extern**：计数器、寄存器、哈希、摘要……下一章就讲 [12 · 外部对象 Extern](./12-外部对象Extern.md)。
