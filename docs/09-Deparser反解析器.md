# 09 · Deparser 反解析器

> 本章目标：把处理完的 headers **重新拼回字节流**。这一章相对简单，但一定要弄懂 `emit` 的语义——忘记 `setValid` 是 P4 新手最常见的坑。

## 9.1 Deparser 的职责

Parser 的逆过程：

```text
修改后的 headers ─► [Deparser] ─► 字节流 ─► 交给硬件/架构发送
```

Deparser 的任务很单纯：**按顺序把有效的 headers 写回输出缓冲区**。

> [!TIP]
> P4_16 没有一个专门的 `deparser` 语法关键字。Deparser 是 **带有 `packet_out` 参数的 control 块**。架构描述里定义了它的形状。

## 9.2 一个最小 Deparser

```p4
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}
```

按你希望在线上出现的顺序 `emit`。这和 Parser 里提取的顺序通常是 **相反的（外层 → 内层）**，但按"目标报文线型"排即可。

## 9.3 `packet_out.emit` 的语义

`core.p4` 里的声明：

```p4
extern packet_out {
    void emit<T>(in T data);
}
```

语义伪代码：

```text
emit(data):
    if T 是 header：
        if data.valid$ == true:
            追加 data 到 packet
    else if T 是 header stack：
        for e in data: emit(e)
    else if T 是 header_union 或 struct：
        for field in data.fields$: emit(field)
    else:
        非法   // 例如 emit 一个纯 bit<> 或 enum
```

**三条关键规则**：

1. **只有 valid 的 header 会被写入**——invalid 自动跳过，不报错
2. header stack / struct / header_union 会 **递归** 处理
3. 非 header 的原始类型**不能**直接 emit

## 9.4 "忘记 setValid" 的经典 bug

```p4
// Ingress 里新加了一层 VLAN
action push_vlan() {
    hdr.vlan.pcp       = 0;
    hdr.vlan.dei       = 0;
    hdr.vlan.vid       = 100;
    hdr.vlan.etherType = hdr.ethernet.etherType;
    hdr.ethernet.etherType = 0x8100;
    // ❌❌❌ 忘了 hdr.vlan.setValid();
}
```

Deparser 里写了：

```p4
packet.emit(hdr.ethernet);
packet.emit(hdr.vlan);     // ← vlan 无效，整层被跳过
packet.emit(hdr.ipv4);
```

结果：etherType 已经变成 0x8100，但线上**没有 VLAN 层**——接收端必挂。

> [!WARNING]
> **铁律**：凡是 Ingress/Egress 里"新增"一层 header，就要 `hdr.X.setValid()`；凡是"删除"一层，就要 `hdr.X.setInvalid()`。

## 9.5 Emit 的三类常见对象

### 9.5.1 单个 header

```p4
packet.emit(hdr.ethernet);
```

### 9.5.2 header 结构体

`emit` 一个结构体 = 按字段顺序递归 emit：

```p4
struct headers {
    ethernet_t ethernet;
    vlan_t     vlan;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

// Deparser 里一次 emit 整个 struct：
packet.emit(hdr);
```

**顺序** = 结构体里字段声明的顺序。想换顺序？要么调整 struct 定义，要么逐个 `emit`。

### 9.5.3 header stack

```p4
packet.emit(hdr.mpls);   // 栈里每个 valid 元素依次 emit
```

## 9.6 一个完整例子：Ethernet + VLAN + IPv4 + TCP

```p4
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.vlan);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
    }
}
```

哪些真正上线，完全取决于各 header 的 valid 位：

- Parser 里能解析出 VLAN → `hdr.vlan` valid
- Ingress 里做 VLAN pop → `hdr.vlan.setInvalid()`
- 最终线上就没有 VLAN

这就是 P4 "声明式 + valid 位" 设计的威力。

## 9.7 Deparser 能不能写逻辑？

**理论上可以**——它是个 control 块，里面可以写 `if`、调 `action`、调表（如果架构允许）。但最佳实践是：

> **Deparser 只负责 `emit`，不写业务逻辑**。

业务逻辑（包括计算校验和）要放到专门的 control 块或 Egress 里。

### 9.7.1 例外：校验和

一些架构把校验和**计算**放在 Deparser 旁边的专门 control 里：

- V1Model：独立的 `ComputeChecksum` 控制块
- PSA：类似
- VSS：放在 Deparser 里手动做

**V1Model 典型写法**：

```p4
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),               // 只在 valid 时算
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr); }
}
```

## 9.8 字节 / 位对齐

P4 的所有 header 字段加起来必须是 **8 bit 的整数倍**——字节对齐。如果不是，编译器会报错。

`varbit` 字段的实际长度由 `extract` 时传入的参数决定；Deparser 会原样回写这段长度。

## 9.9 "不见了"的字段 —— Emit 不写什么

- **元数据（metadata / standard_metadata）**：只是流水线内部信息，Deparser 不应 emit 它们
- **无效 header**：自动跳过
- **未修改字段**：照原样回写（valid 位以外没有"脏位"概念）

## 9.10 本章小结

- Deparser = 带 `packet_out` 的 control 块，典型只写 `emit`
- `emit(h)` 只在 `h.isValid() == true` 时真的写入
- emit 可递归处理 struct / header stack / header_union
- 新增一层 header → 记得 `setValid()`；删除一层 → `setInvalid()`
- 校验和计算通常放在单独的控制块（V1Model 的 `ComputeChecksum`）

## 9.11 下一步

到这里，P4_16 的 **核心语法 + 三大可编程块** 都过完了。现在你能看懂和写出一个完整的 P4 程序——但它要跑起来，还需要理解 **架构（Architecture）**。进入 [10 · 架构与包](./10-架构与包.md)。
