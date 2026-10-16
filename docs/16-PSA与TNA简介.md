# 16 · PSA 与 TNA 简介

本章介绍 PSA、TNA、PNA 的处理模型，并通过 BMv2 双端口实验说明从 V1Model 迁移到 PSA 时需要处理的接口与报文语义。

本章以 [PSA 1.2](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PSA-v1.2.html) 和 [PNA 0.7](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PNA-v0.7.html)为参考。PSA 实验使用 p4c `1.2.5.10`（`8b6de3c57`）和 BMv2 `1.15.0-2bdd0b7b`。TNA 部分核对公开接口与工具链说明，不包含 Tofino 硬件实测。

## 16.1 为什么要了解其他架构

V1Model 提供了本教程前面使用的 Parser、控制块、校验和块、Deparser 和 extern 接口。它沿用了 P4_14 的交换机处理模型，在 BMv2 上有明确的实现语义，适合学习和软件实验。`digest`、克隆等接口的细节见[第 11 章](11-V1Model架构.md)和[第 12 章](12-外部对象Extern.md)。

P4₁₆ 将语言与架构分开，迁移前需要回答三个问题：

1. 目标编译器接受哪一种架构、哪一版头文件？
2. 该实现支持哪些报文路径、extern 和控制平面操作？
3. 表容量、字段位宽、状态访问和流水线依赖是否能映射到目标资源？

PSA 规定交换机的公共接口与行为，目的是提高符合该架构的实现之间的可移植性。TNA 则针对 Tofino 的处理能力定义接口，程序按所选目标采用相应架构。

## 16.2 PSA 概览

PSA（Portable Switch Architecture，可移植交换机架构）由 P4.org 架构工作组定义，规定了可编程块的接口、报文路径和常用 extern 的行为。

### 16.2.1 流水线与报文重解析

PSA 包含六个 P4 可编程块，以及 PRE、BQE 两个固定功能块。普通报文的处理路径可简化为：

```text
端口 → IngressParser → Ingress → IngressDeparser → PRE
                                                    ↓
端口 ← BQE ← EgressDeparser ← Egress ← EgressParser ←
```

PRE（Packet Replication Engine）承担多播、克隆相关的复制处理，BQE（Buffering Queuing Engine）位于 egress 之后，承担输出缓冲与排队。二者是固定功能块，由控制平面配置和报文元数据选择架构规定的行为。

普通报文经 ingress deparser 重组为字节流，再进入 egress parser。Ingress 和 egress 可以使用同一个 `headers_t` 类型定义，egress 中的头部值和有效性由它自己的 parser 建立。两侧报文格式相同时，可以复用解析、反解析代码。

Resubmit 重新处理本次 ingress parser 收到的原始报文字节，recirculate 则在 egress deparser 之后，把重组后的报文送回 ingress parser。

PSA 为不同报文路径分别定义用户元数据参数。普通路径由 ingress deparser 的 `normal_meta` 传给 egress parser，克隆、resubmit、recirculate 使用各自参数。Deparser 按 `psa_normal`、`psa_clone_i2e` 等路径判断函数决定是否填写相应输出。

本机 `p4c-bm2-psa` 在 deparser 中调用 `psa_normal` 并赋值 `normal_meta` 时会报 `unsupported`。16.6 节的可运行示例将这些路径元数据设为空结构。

### 16.2.2 输入、输出元数据

PSA 按阶段与方向划分元数据，以下只列迁移时常用的字段，完整定义以目标工具链的 `psa.p4` 为准。

| 类型                                  | 主要字段与用途                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------------- |
| `psa_ingress_parser_input_metadata_t` | `ingress_port`、`packet_path`，提供入口端口与到达路径                              |
| `psa_ingress_input_metadata_t`        | 另含 `ingress_timestamp`、`parser_error`，供 ingress control 读取                  |
| `psa_ingress_output_metadata_t`       | `drop`、`egress_port`、`multicast_group`、`class_of_service`、克隆与 resubmit 字段 |
| `psa_egress_parser_input_metadata_t`  | `egress_port`、`packet_path`                                                       |
| `psa_egress_input_metadata_t`         | 另含 `instance`、`class_of_service`、`egress_timestamp`、`parser_error`            |
| `psa_egress_output_metadata_t`        | `drop` 与克隆字段，输出端口由 ingress 选择                                         |

`packet_path` 用于区分 `NORMAL`、`NORMAL_UNICAST`、`NORMAL_MULTICAST`、`CLONE_I2E`、`CLONE_E2E`、`RESUBMIT`、`RECIRCULATE` 等到达路径。解析错误通过相应 control 输入的 `parser_error` 检查。

**Ingress 的 `drop` 初始为 `true`，egress 的 `drop` 初始为 `false`**。普通单播需要设置输出端口并清除 ingress 的丢弃标记，`send_to_port(ostd, port)` 会完成这两步，同时将 `multicast_group` 置零。它保留已有的 resubmit 和克隆请求，`ingress_drop` 则阻止普通转发与 resubmit，独立的克隆请求仍可生效。

`PortId_t` 等架构类型的底层位宽由实现选择。本机 BMv2 头文件将 `PortId_t` 定义为以 `bit<32>` 为底层的新类型，示例用 `(PortId_t) 1` 显式构造端口值。涉及控制平面表示时，还需按架构文件中的类型翻译声明处理。

### 16.2.3 顶层 package

下面摘录架构头文件中的 package 声明，用于核对各实例的类型和装配顺序：

```p4
package PSA_Switch<IH, IM, EH, EM, NM, CI2EM, CE2EM, RESUBM, RECIRCM>(
    IngressPipeline<IH, IM, NM, CI2EM, RESUBM, RECIRCM> ingress,
    PacketReplicationEngine pre,
    EgressPipeline<EH, EM, NM, CI2EM, CE2EM, RECIRCM> egress,
    BufferingQueueingEngine bqe);
```

`IH/IM`、`EH/EM` 分别是 ingress、egress 的头部与用户元数据类型。`NM` 表示普通 ingress → egress 元数据，`CI2EM`、`CE2EM` 分别用于 ingress → egress、egress → egress 克隆，`RESUBM`、`RECIRCM` 用于重新提交与再循环。PRE 与 BQE 本身没有这些泛型参数。

程序通过两个 pipeline 实例连接六个可编程块，再实例化 `PSA_Switch`。16.6 节给出完整代码，其中不需要携带额外元数据的路径使用空结构。

### 16.2.4 Extern 接口与调用位置

| PSA 接口                            | 需要注意的语义                                                                     |
| ----------------------------------- | ---------------------------------------------------------------------------------- |
| `Counter<W, S>`、`DirectCounter<W>` | `W` 是计数值类型，如 `bit<64>`，`S` 是索引类型                                     |
| `Meter<S>`、`DirectMeter`           | `execute` 返回 `PSA_MeterColor_t`，程序据此决定报文处理方式                        |
| `Register<T, S>`                    | `read(index)` 返回 `T`，`write(index, value)` 写入，未提供初值时元素的初始值未定义 |
| `Hash<O>`、`Checksum<W>`            | 泛型参数表示结果类型，具体算法和资源范围由目标支持                                 |
| `InternetChecksum`                  | 计算 16 位反码和，支持增量更新，可用于 IPv4、TCP、UDP 的校验和处理                 |
| `Digest<T>`                         | `pack(data)` 向控制平面发送类型为 `T` 的结构化数据                                 |
| `ActionProfile`、`ActionSelector`   | 前者复用动作成员，后者从组内选择成员执行，可用于 ECMP，多播复制由 PRE 完成         |

Extern 的可调用位置属于架构约束。例如，PSA 的 `Digest` 位于 **IngressDeparser**，`Checksum` 与 `InternetChecksum` 位于 parser 或 deparser，计数器、计量器和寄存器位于 ingress 或 egress control。迁移时应把实例和调用放在对应处理块中。

需要原子读改写时，应按[第 12 章](12-外部对象Extern.md)的方法明确寄存器操作的原子范围，并核对目标支持。

## 16.3 V1Model 与 PSA 对照

| 项目           | V1Model / 本教程的 BMv2 目标                                       | PSA                                                 |
| -------------- | ------------------------------------------------------------------ | --------------------------------------------------- |
| 可编程块       | Parser、VerifyChecksum、Ingress、Egress、ComputeChecksum、Deparser | ingress、egress 各有 parser、control、deparser      |
| 普通路径的头部 | ingress 到 egress 传递已解析的头部状态                             | ingress 反解析，egress 重新解析                     |
| 架构元数据     | `standard_metadata_t` 集中提供                                     | 按阶段拆分输入与输出结构                            |
| 普通转发       | 设置 `egress_spec`，丢弃有专用语义                                 | 设置输出选择并清除 ingress 的 `drop`                |
| 多播           | 设置 `mcast_grp`，控制平面配置复制组                               | 设置 `multicast_group` 并允许转发，控制平面配置 PRE |
| 解析错误       | `standard_metadata.parser_error`                                   | ingress、egress control 各自读取 `parser_error`     |
| 摘要           | `digest<T>(receiver, data)`                                        | `Digest<T>` 实例及 `pack(data)`，调用位置不同       |
| 本机编译、执行 | `p4c-bm2-ss`、`simple_switch` / `simple_switch_grpc`               | `p4c-bm2-psa`、`psa_switch`                         |

P4Runtime 定义控制平面通信，PSA、V1Model 等架构定义数据平面接口，具体控制服务由目标实现提供。例如，V1Model 的 `simple_switch_grpc` 提供 P4Runtime，本章的 `psa_switch` 实验使用文件收发。BMv2 各目标的接口见[官方说明](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/targets/README.md)。

## 16.4 TNA：面向 Tofino 的架构

TNA（Tofino Native Architecture）描述 Tofino 的可编程处理接口，包括 intrinsic metadata、pipeline package 和硬件相关 extern。Tofino 2 工具链还提供 `t2na.p4`，所用接口应结合芯片型号、编译目标和 SDK 版本确定。

### 16.4.1 Pipeline 与物理 pipe

一个 TNA `Pipeline` 实例连接 ingress、egress 各自的 parser、control 和 deparser。芯片的物理 pipe 数量、可用端口及其映射由具体型号和设备配置决定。

公开的 [`tofino1_arch.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/tofino/bf-p4c/p4include/tofino1_arch.p4)中，`Switch` 接口包含一个必选和三个可选的 `Pipeline` 参数，用于描述逻辑 pipeline。逻辑实例与物理 pipe 的部署关系，以及表和状态的作用域，由驱动与控制平面配置。

TNA 的 intrinsic metadata 提供端口、解析状态、流量管理等信息，普通用户元数据从 ingress 到 egress 的传递则需按目标约定安排。

### 16.4.2 状态操作与硬件约束

TNA 的 `Register<T, I>` 与 `RegisterAction<T, I, U>` 配合使用。后者绑定一个寄存器实例，通过实现 `apply` 定义读改写逻辑，再用 `execute(index)` 执行。一次 `execute` 对指定单元的读改写是原子的，`apply` 中的计算须满足状态 ALU 的限制。接口见 [`tofino1_base.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/tofino/bf-p4c/p4include/tofino1_base.p4)。

同一头文件还定义了 `Counter`、`Meter`、`Lpf`、`Wred`、`Mirror`、`Digest`、`Resubmit` 等对象。使用时按 TNA 接口核对构造参数、调用位置和数据格式。

硬件编译时需要同时满足几类限制：

- **流水线依赖**：有数据依赖的操作需要按可实现的顺序放置。一张表可能分布在多个 stage，多张表也可能共享一个 stage，具体结果由编译器的资源映射决定。
- **查找与存储资源**：匹配键宽度、表项数、SRAM/TCAM 分配、动作数据都可能限制放置。
- **字段与状态资源**：报文头向量（PHV）的空间和访问方式、状态 ALU 能执行的操作，都会影响程序能否映射。
- **解析与反解析能力**：可解析的深度、提取方式和输出格式有目标限制。反复 recirculate 还会增加内部处理流量，影响吞吐与时延。

检查编译结果时，应区分语言规则与硬件能力。P4₁₆ 没有浮点类型，运行时算术的支持范围还受目标限制。编译期常量表达式由编译器求值，逐包计算则需要相应硬件资源。遇到资源不足、依赖无法满足或不支持的操作时，结合诊断与资源报告判断原因。

### 16.4.3 公开工具链与硬件部署

本章引用的 p4c 提交包含公开的 Tofino 后端与架构头文件。[Open P4Studio 的项目说明](https://github.com/p4lang/open-p4studio/blob/36838d82a59b0334d9368d6401c4ed6bd5fee214/README.md)介绍了可构建的模型代码、运行模型所需的驱动、BF Runtime 接口及示例。学习 TNA 可以从这些公开代码入手。BF Runtime 与第 15 章的 P4Runtime 是不同的控制平面接口，客户端与对象描述需要分别处理。

硬件部署还需配套的 BSP、ASIC 专用 SerDes 驱动等组件，其版本须与设备和 SDE 匹配。上述 README 同时公告，Intel 自 **2026-01-01** 起停止批准此类新的访问申请。

## 16.5 PNA：面向 NIC 的架构

PNA（Portable NIC Architecture）面向网络接口与主机之间的报文处理。本章引用的 **0.7 版是工作草案**，发布于 2022-12-22。

该版本定义 `MainParser → MainControl → MainDeparser` 三个主要可编程块。来自网络和来自主机的报文共用这些块，由程序选择网络端口、主机接口或其他允许的路径。队列、消息处理和可选的 inline accelerator 由具体目标提供相应支持。

选择可编程 NIC 时，应确认具体型号开放的 P4 编译与部署接口。对于 DPDK、eBPF 等执行环境，也应核对所用后端接受的架构及其支持范围。

## 16.6 从 V1Model 迁移到 PSA

### 16.6.1 按报文行为迁移

迁移时可以保留协议头定义、与目标无关的匹配逻辑，再逐项处理架构差异：

1. 确定两个 parser/deparser 之间实际传输的字节格式，以及 egress 需要重新提取的字段。
2. 为普通、克隆、resubmit、recirculate 路径分别确定元数据的产生点与使用点，并为循环路径设置终止条件。
3. 改写端口选择、丢弃、多播、解析错误和校验和处理，检查字段初值与类型转换。
4. 替换 extern 的构造、方法和调用位置，并核对初值、索引范围与原子性。
5. 调整控制平面对象、端口映射、PRE 配置和目标启动方式，按新生成的接口描述查找对象 ID。
6. 用同一组输入报文与期望结果验证两个版本，再对新架构特有路径补充测试。

### 16.6.2 一个完整的双端口示例

下面的程序在端口 1、2 之间双向转发，解析不出完整以太网头或来自其他端口时丢弃。转发方向由入端口决定，可用它观察 PSA 的六个块如何连接。

从仓库根目录创建输出目录：

```bash
mkdir -p build/ch16
```

将以下代码保存为 `build/ch16/psa_pair.p4`。这里包含 p4c 的 `bmv2/psa.p4`，使用 BMv2 的类型定义，换用其他目标时应选择对应工具链的架构文件。

```p4
#include <core.p4>
#include <bmv2/psa.p4>

header ethernet_t {
    bit<48> dst;
    bit<48> src;
    bit<16> ether_type;
}
struct headers_t { ethernet_t ethernet; }
struct empty_t { }

parser IngressParserImpl(packet_in packet, out headers_t hdr,
                        inout empty_t meta,
                        in psa_ingress_parser_input_metadata_t istd,
                        in empty_t resubmit_meta,
                        in empty_t recirculate_meta) {
    state start {
        packet.extract(hdr.ethernet);
        transition accept;
    }
}

control IngressImpl(inout headers_t hdr, inout empty_t meta,
                    in psa_ingress_input_metadata_t istd,
                    inout psa_ingress_output_metadata_t ostd) {
    apply {
        if (istd.parser_error == error.NoError && hdr.ethernet.isValid()) {
            if (istd.ingress_port == (PortId_t) 1) {
                send_to_port(ostd, (PortId_t) 2);
            } else if (istd.ingress_port == (PortId_t) 2) {
                send_to_port(ostd, (PortId_t) 1);
            }
        }
    }
}

control IngressDeparserImpl(packet_out packet,
                          out empty_t clone_i2e_meta,
                          out empty_t resubmit_meta,
                          out empty_t normal_meta,
                          inout headers_t hdr, in empty_t meta,
                          in psa_ingress_output_metadata_t istd) {
    apply { packet.emit(hdr.ethernet); }
}

parser EgressParserImpl(packet_in packet, out headers_t hdr,
                       inout empty_t meta,
                       in psa_egress_parser_input_metadata_t istd,
                       in empty_t normal_meta,
                       in empty_t clone_i2e_meta,
                       in empty_t clone_e2e_meta) {
    state start {
        packet.extract(hdr.ethernet);
        transition accept;
    }
}

control EgressImpl(inout headers_t hdr, inout empty_t meta,
                   in psa_egress_input_metadata_t istd,
                   inout psa_egress_output_metadata_t ostd) {
    apply {
        if (istd.parser_error != error.NoError || !hdr.ethernet.isValid()) {
            egress_drop(ostd);
        }
    }
}

control EgressDeparserImpl(packet_out packet,
                         out empty_t clone_e2e_meta,
                         out empty_t recirculate_meta,
                         inout headers_t hdr, in empty_t meta,
                         in psa_egress_output_metadata_t istd,
                         in psa_egress_deparser_input_metadata_t edstd) {
    apply { packet.emit(hdr.ethernet); }
}

IngressPipeline(IngressParserImpl(), IngressImpl(), IngressDeparserImpl()) ip;
EgressPipeline(EgressParserImpl(), EgressImpl(), EgressDeparserImpl()) ep;
PSA_Switch(ip, PacketReplicationEngine(), ep, BufferingQueueingEngine()) main;
```

程序只解析以太网头，剩余字节作为未解析负载保留。Ingress deparser 输出以太网头后，目标接上该负载。Egress parser 从重组后的字节流中提取头部，egress deparser 再完成相同的重组过程。

编译并检查实验依赖：

```bash
command -v p4c-bm2-psa psa_switch
p4c-bm2-psa --std p4-16 --Werror \
  -o build/ch16/psa_pair.json build/ch16/psa_pair.p4
python3 -c 'import scapy; print(scapy.__version__)'
```

若导入失败，应选择已安装 Scapy 的 Python 环境，参见[第 1 章](01-环境搭建.md)。本次使用 Scapy `2.5.0`，BMv2 构建时需启用 `psa_switch` 目标。

### 16.6.3 用 PCAP 验证转发与丢弃

将以下脚本保存为 `build/ch16/verify_pair.py`，使用上一步选定的 Python 运行。它通过 BMv2 的文件接口收发，不创建 Mininet 拓扑，也不需要 sudo。`--thrift-port 9096` 须为空闲端口，若冲突可修改该值。

```python
from pathlib import Path
from contextlib import closing
import subprocess
from scapy.utils import PcapWriter, RawPcapReader

root = Path(__file__).resolve().parent

def frame(port, length):
    header = bytes.fromhex("02000000000202000000000188b5")
    return header + bytes([port]) * (length - len(header))

valid = {p: [frame(p, n) for n in (60, 128, 1514)] for p in (1, 2)}
inputs = {1: valid[1] + [b"\x00" * 10], 2: valid[2], 3: [frame(3, 60)]}
for port, packets in inputs.items():
    with PcapWriter(str(root / f"p{port}_in.pcap"), linktype=1) as writer:
        writer.write(packets)
    (root / f"p{port}_out.pcap").unlink(missing_ok=True)

command = ["psa_switch", "--use-files", "0", "--device-id", "16",
           "--thrift-port", "9096", "--log-console",
           "--notifications-addr", f"ipc://{root}/notifications.ipc",
           "-i", "1@p1", "-i", "2@p2", "-i", "3@p3", "psa_pair.json"]
with (root / "switch.log").open("w") as log:
    try:
        result = subprocess.run(command, cwd=root, stdout=log,
                                stderr=subprocess.STDOUT, timeout=5)
    except subprocess.TimeoutExpired:
        pass  # 文件读完后交换机仍常驻；run 已结束并回收此子进程。
    else:
        raise RuntimeError(f"交换机提前退出：{result.returncode}，请查看 switch.log")

def packets(port):
    path = root / f"p{port}_out.pcap"
    if path.stat().st_size == 0:  # 此版本在没有输出报文时不刷新 PCAP 文件头。
        return []
    with closing(RawPcapReader(str(path))) as reader:
        return [data for data, _ in reader]

assert packets(1) == valid[2], "端口 2 → 1 的报文不一致"
assert packets(2) == valid[1], "端口 1 → 2 的报文不一致"
assert packets(3) == [], "端口 3 不应有输出"
text = (root / "switch.log").read_text()
assert text.count("Dropping packet at the end of ingress") == 2
print("PASS: 6 帧双向转发且逐字节一致，2 帧按预期丢弃")
```

```bash
python3 build/ch16/verify_pair.py
```

测试输入包含两个方向各 3 帧（60、128、1514 字节，不含 FCS），另有 1 帧仅 10 字节的短报文和 1 帧来自端口 3 的报文。期望输出为六帧逐字节一致的转发结果，另两帧在 ingress 被丢弃。程序检查范围是以太网头，短报文用于触发头部提取失败。

`psa_switch` 读完输入后仍驻留，因此脚本在 5 秒后终止并回收自己启动的子进程，再检查 PCAP 和日志，全部断言通过后输出 `PASS`。机器启动较慢时可调大 `timeout`。编译失败时查看编译器诊断，运行失败时检查 `build/ch16/switch.log`。

## 16.7 按目标与工具链选型

| 需求                   | 可考察的架构或工具             | 先核对的条件                                  |
| ---------------------- | ------------------------------ | --------------------------------------------- |
| 复现本教程的软件实验   | V1Model + BMv2                 | 编译器、目标程序、控制平面与测试版本匹配      |
| 研究可移植交换机程序   | PSA 及具体实现                 | 所需路径、extern、资源容量与控制平面支持      |
| 为已有 Tofino 设备开发 | 对应版本的 TNA / T2NA 与 SDK   | 芯片型号、编译映射、BSP、驱动和设备配置       |
| 可编程 NIC 实验        | PNA 或设备专用架构             | 型号是否开放所需的 P4 编译和部署接口          |
| Linux 内核报文处理     | p4c 的 eBPF 后端及其支持的架构 | TC/XDP 位置、内核能力、加载器与 verifier 限制 |
| DPDK 用户态处理        | `p4c-dpdk` 的 PSA/PNA 支持     | DPDK SWX 运行环境、后端特性与版本限制         |

例如，本章所用 p4c 提交中的 [PSA/eBPF 实现](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/ebpf/psa/README.md)区分 TC 与 XDP 路径，XDP 路径尚不支持 recirculate、QoS 和 `CLONE_E2E`。[DPDK 后端文档](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/dpdk/README.md)列出了 PSA/PNA 输入及其实现限制，使用时按所需功能核对相应后端。

本教程保留 V1Model 作为主要实验架构。需要迁移时，除改写接口外，还应验证报文内容、状态访问、控制平面和资源使用是否符合目标要求。

## 16.8 资源指引

- [PSA 1.2 规范](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PSA-v1.2.html)：核对报文路径、元数据初值、extern 与固定功能块。
- [p4c 的 BMv2 PSA 接口](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/p4include/bmv2/psa.p4)：对应本章实验所用编译器版本。
- [PNA 0.7 草案](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PNA-v0.7.html)：阅读 NIC 路径、主机接口与加速器模型。
- [p4c Tofino 后端](https://github.com/p4lang/p4c/tree/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/tofino)：阅读公开架构接口、编译器实现和资源映射代码。
- [Open P4Studio 项目说明（本章引用版本）](https://github.com/p4lang/open-p4studio/blob/36838d82a59b0334d9368d6401c4ed6bd5fee214/README.md)：核对模型、驱动、示例和硬件部署的附加条件。

## 16.9 本章小结

PSA、TNA 和 PNA 分别从可移植交换机、Tofino 目标和 NIC 的角度定义数据平面接口。PSA 的 ingress/egress 重解析、默认丢弃和分路径元数据，是从 V1Model 迁移时首先需要处理的差异。TNA 还要求程序满足具体硬件的放置与状态操作限制。

选择架构后，按目标工具链完成编译、报文验证和资源检查，并核对所需的控制平面操作。

## 16.10 学完之后

主正文之后，可以按需要继续阅读附录或扩展实验：

- [附录 A · core.p4 解析](../appendix/A-核心库core.p4解析.md)：回顾跨架构使用的核心接口。
- [附录 B · 术语表](../appendix/B-术语表.md)：对照英文规范与论文中的术语。
- [附录 C · 学习资源](../appendix/C-学习资源.md)：查找后续阅读材料。
- [附录 D · 常见问题](../appendix/D-常见问题.md)：按故障现象排查工具链与实验环境。
- [`examples/`](../examples)：为已有程序补充边界报文，或尝试迁移到已经具备运行条件的目标。
