# 16 · PSA 与 TNA 简介

> 本章目标：知道 **PSA（Portable Switch Architecture）** 和 **TNA（Tofino Native Architecture）** 是什么、它们和 V1Model 的区别，帮你未来从学习走向生产时少走弯路。

## 16.1 为什么要换掉 V1Model

V1Model 的问题：

- 只是 BMv2 示范用，**不是 P4.org 的正式标准**
- Metadata 布局写死（`standard_metadata_t`）
- 有些 extern（`digest`、`clone_preserving_field_list`）语义含糊
- 不能覆盖真实芯片的多流水线、多阶段架构

于是 P4.org 搞了两件事：

1. 制定了 **PSA** 标准——"所有实现都应遵守"的最大公约数
2. 厂商（Intel Tofino）出自家 **TNA**——最能体现硬件能力

## 16.2 PSA 概览

PSA（[Portable Switch Architecture](https://p4.org/p4-spec/docs/PSA.html)）是 P4.org 官方定义的**可移植交换机架构**。

### 16.2.1 流水线

```text
Packet ─► IngressParser ─► Ingress ─► IngressDeparser ─► [PRE+TM+BQE] ─► EgressParser ─► Egress ─► EgressDeparser ─► Packet
```

- **IngressParser / IngressDeparser 独立** —— 不和 V1Model 一样共享同一个 headers 结构
- PRE = Packet Replication Engine（多播）
- TM = Traffic Manager（队列、优先级）
- BQE = Buffer Queuing Engine

### 16.2.2 预定义元数据

```p4
struct psa_ingress_parser_input_metadata_t {
    PortId_t         ingress_port;
    PSA_PacketPath_t packet_path;
}

struct psa_ingress_output_metadata_t {
    ClassOfService_t class_of_service;
    bool             clone;
    CloneSessionId_t clone_session_id;
    bool             drop;
    bool             resubmit;
    MulticastGroup_t multicast_group;
    PortId_t         egress_port;
}
```

注意：**不再有一个万能的 `standard_metadata_t`**——每个阶段有各自的输入/输出元数据，更明确。

### 16.2.3 顶层 package

```p4
package PSA_Switch<IH, IM, EH, EM, NM, CI2EM, RESUBM, CI2RI, RI2EM>(
    IngressPipeline<IH, IM, NM, CI2EM, RESUBM, CI2RI> ingress,
    PacketReplicationEngine<IM, CI2RI> pre,
    EgressPipeline<EH, EM, NM, CI2EM, RI2EM, RESUBM> egress,
    BufferingQueueingEngine<EM, RI2EM> bqe);
```

泛型参数有点多——这是为了精确描述"在 ingress → egress 之间传递的元数据"。

### 16.2.4 PSA Extern

PSA 规范化了之前各家不同的 extern：

- `Counter<W, S>(size, type)`
- `Meter<S>(size, type)`
- `Register<T, S>(size)`（注意：`read(idx)` 返回 T）
- `Hash<O>(algo)`
- `Checksum<W>(algo)`
- `InternetChecksum()`（专给 IPv4 checksum 优化）
- `Digest<T>()` —— 比 V1Model 更类型安全
- `ActionProfile` / `ActionSelector` —— 用于 ECMP / 组播组

## 16.3 V1Model vs PSA 对照

| 项目 | V1Model | PSA |
| ---- | ------- | --- |
| 流水线 | Ingress + Egress 共享 Parser/Deparser | Ingress + Egress 各自 Parser/Deparser |
| 元数据 | 单个 `standard_metadata_t` | 多种结构：ingress parser / ingress output / egress parser / ... |
| 多播 | `mcast_grp` 字段 | `PacketReplicationEngine` |
| Counter | V1 自家 `counter` | `Counter<W, S>`（标准接口） |
| Digest | 魔法式 `digest<T>(receiver, data)` | 类型化 `Digest<T>`，`.pack(data)` |
| Parser 错误 | `std_meta.parser_error` | `psa_ingress_parser_input_metadata_t.packet_path` + 单独字段 |
| 学习 | digest 手动 | Digest + PacketIn/Out 标准化 |

## 16.4 TNA：Tofino 的"真实架构"

TNA = Tofino Native Architecture。Intel Tofino（和 Tofino 2）系列可编程交换机芯片所用。**闭源**，发行于 SDE（Software Development Environment）中。

### 16.4.1 TNA 的多流水线

Tofino 有 4 条独立的 pipe，每条 pipe 都是一个完整的 ingress+egress：

```text
               ┌── Pipe 0 (Ingress + Egress)
  Ports 0-15 ──┤
               └── ...

               ┌── Pipe 1
  Ports 16-31──┤
               └── ...
  ...
```

你的 P4 程序可以针对不同 pipe 写不同逻辑。

### 16.4.2 TNA 特有 extern

- `Register<T, I>` —— 硬件 SRAM 支撑的并行寄存器
- `RegisterAction<T, I, U>` —— 原子 read-modify-write，绑定到某个 action
- `Counter`、`Meter`、`LPF`（Low-Pass Filter）、`WRED` 等生产级统计
- `Mirror`、`Digest`、`Resubmit` 与 PSA 类似但有硬件细节

### 16.4.3 关键限制

Tofino 是 ASIC，物理资源非常有限：

- Stage 数量固定（12 个左右）——**表不能超过这么多阶段**
- 每 stage 内存分配：SRAM、TCAM、ALU，**编译器要排满这条流水线**
- 不能做 "for each packet execute long algorithm" 这种软件思路
- 没有浮点、没有除法（需要用查找表近似）

写 TNA 代码要对 "stage pressure" 很敏感。`p4c-tofino` 编译失败最常见的原因是 **资源不足**。

## 16.5 PNA：面向 NIC 的架构

PNA（Portable NIC Architecture）是 P4.org 最新（2022）标准化的 **智能网卡架构**。

- 加入 "host → NIC → network" 两阶段模型
- 支持 NIC 特有场景（vHost、virtio-net 加速）

想做 DPDK / SmartNIC / eBPF 的 P4，可以关注。

## 16.6 迁移建议：从 V1Model 到 PSA

把一份 V1Model 程序迁到 PSA，大致步骤：

1. 拆出 **IngressParser** 和 **EgressParser**（不要共享）
2. 拆出 **IngressDeparser** 和 **EgressDeparser**
3. 把 `standard_metadata` 改成 PSA 的 `psa_ingress_*` 对应字段
4. Counter / Meter / Register 改成 `Counter<W, S>` 等标准接口
5. 多播：从 `mcast_grp = N` 改成在 PRE 里配置 group + 设 `ostd.multicast_group = N`

开销不小，但一次到位。

## 16.7 今天的现状与选型

| 场景 | 推荐架构 |
| ---- | -------- |
| 学习、教学、论文复现 | **V1Model**（BMv2） |
| 跨厂商生产 | PSA（如果厂商支持） |
| Intel Tofino 商用 | TNA |
| 智能网卡 (Xilinx, NVIDIA BlueField, Intel Mount Evans) | PNA 或厂商自家 |
| Linux 内核 eBPF | `p4c-ebpf` 后端（有限支持） |
| DPDK 用户态 | `p4c-dpdk` 后端 |

**本教程以 V1Model 为主**——因为它门槛最低、工具链最成熟。但掌握核心语言概念后，切换到 PSA/TNA 主要是"了解新架构的 API"，而不是学新语言。

## 16.8 资源指引

- PSA 规范：[p4.org/p4-spec/docs/PSA.html](https://p4.org/p4-spec/docs/PSA.html)
- PNA 规范：[p4.org/p4-spec/docs/PNA.html](https://p4.org/p4-spec/docs/PNA.html)
- Tofino SDE：需向 Intel 申请（学术可免费）
- Open Tofino：[`p4lang/open-tofino`](https://github.com/p4lang/open-tofino) 提供部分公开文档

## 16.9 本章小结

- V1Model 是教学事实标准，但不是正式规范
- PSA 是 P4.org 的可移植架构，生产推荐
- TNA 专属 Intel Tofino，有强大但受限的硬件能力
- 核心语法跨架构通用，切换主要成本在于 extern 与元数据

## 16.10 学完之后

恭喜你读完了主正文。接下来可以：

- 去 [附录 A · core.p4 解析](../appendix/A-核心库core.p4解析.md) 了解最基础库的内部
- 用 [附录 B · 术语表](../appendix/B-术语表.md) 对照英文论文
- 在 [附录 C · 学习资源](../appendix/C-学习资源.md) 里找进阶读物
- 遇到 bug → [附录 D · 常见问题](../appendix/D-常见问题.md)
- 或者直接去 [`examples/`](../examples) 挑一个动手复刻
