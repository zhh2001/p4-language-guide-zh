# 16 · PSA 与 TNA 简介

> 本章目标：区分 PSA、TNA、PNA 的适用范围，理解架构迁移时需要核对的接口与报文语义，并在 BMv2 上运行一个完整的 PSA 程序。

本章以 [PSA 1.2](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PSA-v1.2.html)和 [PNA 0.7](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PNA-v0.7.html)为参考。PSA 实验使用 p4c `1.2.5.10` 和 BMv2 `1.15.0`。TNA 部分核对公开接口与工具链说明，不包含 Tofino 硬件实测。

## 16.1 为什么要了解其他架构

V1Model 提供了本教程前面使用的 Parser、控制块、校验和块、Deparser 和 extern 接口。它沿用了 P4_14 的交换机处理模型，在 BMv2 上有明确的实现语义，适合学习和软件实验。`digest`、克隆等接口的细节见[第 11 章](11-V1Model架构.md)和[第 12 章](12-外部对象Extern.md)。

P4_16 将语言与架构分开，迁移前需要回答三个问题：

1. 目标编译器接受哪一种架构、哪一版头文件？
2. 该实现支持哪些报文路径、extern 和控制平面操作？
3. 表容量、字段位宽、状态访问和流水线依赖是否能映射到目标资源？

PSA 规定交换机的公共接口与行为，目的是提高符合该架构的实现之间的可移植性。TNA 则面向 Tofino 的处理能力。它们并非所有 P4 设备都必须采用的统一接口。

## 16.2 PSA 概览

PSA（Portable Switch Architecture，可移植交换机架构）由 P4.org 架构工作组定义，规定了可编程块的接口、报文路径和常用 extern 的行为。

### 16.2.1 流水线与报文重解析

PSA 包含六个 P4 可编程块，以及 PRE、BQE 两个固定功能块。普通报文的处理路径可简化为：

```text
端口 → IngressParser → Ingress → IngressDeparser → PRE
                                                    ↓
端口 ← BQE ← EgressDeparser ← Egress ← EgressParser ←
```

PRE（Packet Replication Engine）承担多播、克隆相关的复制处理，BQE（Buffering Queuing Engine）位于 egress 之后，承担输出缓冲与排队。二者由架构定义，不能通过编写 P4 控制块任意重写其内部调度算法。控制平面配置与报文元数据可以影响其行为。

普通报文在 ingress 结束后先被反解析，再进入 egress parser。Ingress 和 egress 可以使用同一个 `headers_t` **类型定义**，但 egress 中的头部值和有效性由它自己的 parser 建立，不是直接沿用 ingress 的头部对象。可以复用解析、反解析的公共代码，是否复用取决于两侧报文格式。

跨阶段传递用户元数据也需要显式安排。普通路径使用 ingress deparser 的 `normal_meta` 输出与 egress parser 的对应输入；克隆、resubmit、recirculate 有各自的参数。写入某个路径的元数据、或在下游读取它，都应检查该路径是否成立，不能假定所有参数同时有效。

### 16.2.2 输入、输出元数据

PSA 按阶段与方向划分元数据，以下只列迁移时常用的字段，完整定义以目标工具链的 `psa.p4` 为准。

| 类型                                  | 主要字段与用途                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------------- |
| `psa_ingress_parser_input_metadata_t` | `ingress_port`、`packet_path`，提供入口端口与到达路径                              |
| `psa_ingress_input_metadata_t`        | 另含 `ingress_timestamp`、`parser_error`，供 ingress control 读取                  |
| `psa_ingress_output_metadata_t`       | `drop`、`egress_port`、`multicast_group`、`class_of_service`、克隆与 resubmit 字段 |
| `psa_egress_parser_input_metadata_t`  | `egress_port`、`packet_path`                                                       |
| `psa_egress_input_metadata_t`         | 另含 `instance`、`class_of_service`、`egress_timestamp`、`parser_error`            |
| `psa_egress_output_metadata_t`        | `drop` 与克隆字段；没有可改写的输出端口字段                                        |

`packet_path` 用于区分 `NORMAL`、`NORMAL_UNICAST`、`NORMAL_MULTICAST`、`CLONE_I2E`、`CLONE_E2E`、`RESUBMIT`、`RECIRCULATE`，不是解析错误码。解析错误通过相应 control 输入的 `parser_error` 检查。

有两项初值尤其容易影响迁移：**ingress 的 `drop` 初始为 `true`，egress 的 `drop` 初始为 `false`**。只设置 `egress_port` 不足以启用普通转发；`send_to_port(ostd, port)` 会清除 `drop`、将 `multicast_group` 置零并设置输出端口，但不会取消已经设置的 resubmit 或克隆请求。`ingress_drop` 也不取消独立的克隆请求。

`PortId_t` 等架构类型的底层位宽由实现选择，不应照搬 V1Model 的 `bit<9>`。本机 BMv2 头文件将 `PortId_t` 定义为以 `bit<32>` 为底层的新类型，示例用 `(PortId_t) 1` 显式构造端口值。控制平面的表示还可能涉及类型翻译，不能仅按源程序中的底层位宽猜测。

### 16.2.3 顶层 package

下面是架构头文件中的接口声明摘录，阅读时用于核对参数；程序包含头文件后不应再次声明它。

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

| PSA 接口                            | 需要注意的语义                                                                         |
| ----------------------------------- | -------------------------------------------------------------------------------------- |
| `Counter<W, S>`、`DirectCounter<W>` | `W` 是计数值类型，`S` 是索引类型；例如 `W` 可写成 `bit<64>`，不是裸整数 `64`           |
| `Meter<S>`、`DirectMeter`           | `execute` 返回 `PSA_MeterColor_t`；计量结果如何影响报文由程序决定                      |
| `Register<T, S>`                    | `read(index)` 返回 `T`，`write(index, value)` 写入；未提供初值的构造函数不保证零初始化 |
| `Hash<O>`、`Checksum<W>`            | 泛型参数表示结果类型；支持的算法和资源限制仍需核对目标                                 |
| `InternetChecksum`                  | 计算 16 位反码和，支持增量更新，可用于 IPv4、TCP、UDP 的校验和处理                     |
| `Digest<T>`                         | `pack(data)` 产生控制平面摘要；摘要不等于完整报文，也不负责自动学习 MAC                |
| `ActionProfile`、`ActionSelector`   | 前者复用动作成员，后者从组内选择成员执行，可用于 ECMP；多播复制由 PRE 完成             |

Extern 的可调用位置属于架构约束。例如，PSA 的 `Digest` 位于 **IngressDeparser**，`Checksum` 与 `InternetChecksum` 位于 parser 或 deparser；计数器、计量器和寄存器位于 ingress 或 egress control。仅把 V1Model 的函数名换成 PSA 的名字，可能仍然无法编译。

寄存器的多次读写也不会因为采用 PSA 就自动成为一个事务。需要原子读改写时，应按[第 12 章](12-外部对象Extern.md)的方法明确原子范围，并验证目标能否实现。

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

P4Runtime 是控制平面协议，与架构不是同一个层次。不能因为程序使用 PSA，就推断某个目标一定提供 P4Runtime 服务或完整支持所有实体；V1Model 的 `simple_switch_grpc` 也可以提供 P4Runtime。本机 `psa_switch` 实验使用文件收发，不使用第 15 章的 gRPC 客户端。BMv2 的目标区别见[官方说明](https://github.com/p4lang/behavioral-model/blob/main/targets/README.md)。

## 16.4 TNA：面向 Tofino 的架构

TNA（Tofino Native Architecture）描述 Tofino 的可编程处理接口，包括 intrinsic metadata、pipeline package 和硬件相关 extern。Tofino 2 工具链还提供 `t2na.p4`；使用哪个接口，应结合芯片型号、编译目标和 SDK 版本确定。

### 16.4.1 Pipeline 与物理 pipe

一个 TNA `Pipeline` 实例连接 ingress、egress 各自的 parser、control 和 deparser。芯片的物理 pipe 数量、可用端口及其映射取决于具体型号和设备配置，不能通用地写成“每条 pipe 对应 16 个前面板端口”。

公开的 [`tofino1_arch.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/tofino/bf-p4c/p4include/tofino1_arch.p4)中，`Switch` 接口可接受最多四个 `Pipeline` 实例。这个接口允许描述多个逻辑 pipeline，但不能由此推断所有 Tofino 型号都固定有四条可用物理 pipe。程序部署到哪些 pipe、表和状态采用何种作用域，还需要驱动与控制平面配置。

TNA 的 intrinsic metadata 提供端口、解析状态、流量管理等信息。普通用户元数据从 ingress 带到 egress 时，也要按目标约定进行传递，不能直接套用 V1Model 的共享状态假设。

### 16.4.2 状态操作与硬件约束

TNA 的 `Register<T, I>` 与 `RegisterAction<T, I, U>` 需要一起理解：后者绑定一个寄存器实例，通过实现 `apply` 定义读改写逻辑，再用 `execute(index)` 执行。它提供目标支持的原子状态操作，但 `apply` 中的计算必须满足状态 ALU 的限制，也不能把多个独立的 `execute` 调用视作一个跨寄存器事务。接口见 [`tofino1_base.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/tofino/bf-p4c/p4include/tofino1_base.p4)。

同一头文件还定义了 `Counter`、`Meter`、`Lpf`、`Wred`、`Mirror`、`Digest`、`Resubmit` 等对象。同名或用途相近，并不保证它们与 PSA 的构造参数、调用位置、数据格式一致。

硬件编译时需要同时满足几类限制：

- **流水线依赖**：有数据依赖的操作需要按可实现的顺序放置。源码中一张表不一定占一个 stage，多张表也可能放在同一 stage；“表数量不能超过 stage 数量”不成立。
- **查找与存储资源**：匹配键宽度、表项数、SRAM/TCAM 分配、动作数据都可能限制放置。
- **字段与状态资源**：报文头向量（PHV）的空间和访问方式、状态 ALU 能执行的操作，都会影响程序能否映射。
- **解析与反解析能力**：可解析的深度、提取方式和输出格式有目标限制。反复 recirculate 还会增加内部处理流量，影响吞吐与时延。

不能把语言限制和芯片限制混在一起。例如 P4_16 没有浮点类型，不能期待把通用浮点算法直接搬入数据平面；运行时算术支持则要逐项查目标。常量表达式能被编译器求值，也不代表芯片可以逐包执行相同运算。资源不足、依赖无法满足和不支持的操作都可能导致编译失败，应按诊断与资源报告判断原因。

### 16.4.3 公开工具链与硬件部署

截至 2026/10/03，p4c 已公开 Tofino 后端与架构头文件。[Open P4Studio](https://github.com/p4lang/open-p4studio) 提供可构建的模型代码、运行模型所需的驱动、BF Runtime 接口及示例。学习 TNA 可以从这些公开代码入手。BF Runtime 与第 15 章的 P4Runtime 是不同的控制平面接口，客户端与对象描述需要分别处理。

运行模型与部署到交换机仍有不同条件。该仓库说明硬件需要额外的 BSP、SerDes 驱动等组件，并公告 Intel 自 **2026-01-01** 起停止批准此类新的访问申请。实际部署应核对已有软件授权、设备厂商提供的组件及其版本兼容性；公开源码的可用性并不等于硬件交付条件已经满足。

## 16.5 PNA：面向 NIC 的架构

PNA（Portable NIC Architecture）面向网络接口与主机之间的报文处理。本章引用的 **0.7 版仍是工作草案**，发布于 2022-12-22，不应写成“2022 年发布的最新正式标准”。

该版本定义 `MainParser → MainControl → MainDeparser` 三个主要可编程块。来自网络和来自主机的报文共用这些块，程序再决定送往网络端口、主机接口或其他允许的路径；它不是固定的两条单向流水线。队列、消息处理和可选的 inline accelerator 需要结合目标实现理解。

SmartNIC、DPDK、eBPF 分别涉及设备类别或执行环境，不能仅凭这些名称判断支持 PNA。尤其不能由网卡品牌推断某个型号具备 P4 编译与部署能力，应以该型号的工具链和支持文档为准。

## 16.6 从 V1Model 迁移到 PSA

### 16.6.1 按报文行为迁移

迁移时可以保留协议头定义、与目标无关的匹配逻辑，再逐项处理架构差异：

1. 确定两个 parser/deparser 之间实际传输的字节格式，以及 egress 需要重新提取的字段。
2. 为普通、克隆、resubmit、recirculate 路径分别确定元数据的产生点与使用点；循环路径需要明确终止条件。
3. 改写端口选择、丢弃、多播、解析错误和校验和处理，检查字段初值与类型转换。
4. 替换 extern 的构造、方法和调用位置，并核对初值、索引范围与原子性。
5. 调整控制平面对象、端口映射、PRE 配置和目标启动方式。重新生成接口描述，不能沿用旧程序的对象 ID。
6. 用同一组输入报文与期望结果验证两个版本，再对新架构特有路径补充测试。

### 16.6.2 一个完整的双端口示例

下面的程序将端口 1 的报文送往端口 2，反方向同理；解析不出完整以太网头或来自其他端口时丢弃。它不按 MAC 查表，也不实现 MAC 学习，适合先观察 PSA 的六个块如何连接。

从仓库根目录创建输出目录：

```bash
mkdir -p build/ch16
```

将以下代码保存为 `build/ch16/psa_pair.p4`。这里显式包含 p4c 的 `bmv2/psa.p4`，以使用本次测试目标的类型定义；换用其他目标时应使用对应工具链的架构文件。

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

程序只解析以太网头，剩余字节作为未解析负载保留。Ingress deparser 输出以太网头后，目标接上该负载；egress parser 再提取头部，egress deparser 完成相同的重组过程。两侧使用同一种头部类型，不代表可以省略其中一侧所需的解析。

编译并检查实验依赖：

```bash
command -v p4c-bm2-psa psa_switch
p4c-bm2-psa --std p4-16 --Werror \
  -o build/ch16/psa_pair.json build/ch16/psa_pair.p4
python3 -c 'import scapy; print(scapy.__version__)'
```

若导入失败，应选择已安装 Scapy 的 Python 环境，参见[第 1 章](01-环境搭建.md)。本次使用 Scapy `2.5.0`。`simple_switch` 的存在不能证明 `psa_switch` 已安装，后者需要在构建 BMv2 时启用相应目标。

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

测试输入包含两个方向各 3 帧（60、128、1514 字节，不含 FCS），另有 1 帧仅 10 字节的短报文和 1 帧来自端口 3 的报文。期望输出为六帧逐字节一致的转发结果，另两帧在 ingress 被丢弃。程序不检查上层协议内容；这里的短报文仅用于触发以太网头提取失败。

`psa_switch` 读完输入后仍驻留，因此脚本在 5 秒后终止并回收自己启动的子进程，再检查 PCAP 和日志。超时本身不代表验证成功，断言全部通过才会输出 `PASS`。机器启动较慢时可调大 `timeout`；编译失败时查看编译器诊断，运行失败时检查 `build/ch16/switch.log`。本例验证普通路径与基本丢弃行为，不据此推断该版本完整实现了 PSA 的所有功能。

## 16.7 按目标与工具链选型

| 需求                   | 可考察的架构或工具             | 先核对的条件                                  |
| ---------------------- | ------------------------------ | --------------------------------------------- |
| 复现本教程的软件实验   | V1Model + BMv2                 | 编译器、目标程序、控制平面与测试版本匹配      |
| 研究可移植交换机程序   | PSA 及具体实现                 | 所需路径、extern、资源容量与控制平面支持      |
| 为已有 Tofino 设备开发 | 对应版本的 TNA / T2NA 与 SDK   | 芯片型号、编译映射、BSP、驱动和设备配置       |
| 可编程 NIC 实验        | PNA 或设备专用架构             | 型号是否开放所需的 P4 编译和部署接口          |
| Linux 内核报文处理     | p4c 的 eBPF 后端及其支持的架构 | TC/XDP 位置、内核能力、加载器与 verifier 限制 |
| DPDK 用户态处理        | `p4c-dpdk` 的 PSA/PNA 支持     | DPDK SWX 运行环境、后端特性与版本限制         |

例如，p4c 的 [PSA/eBPF 实现](https://github.com/p4lang/p4c/blob/main/backends/ebpf/psa/README.md)区分 TC 与 XDP 路径，两者支持范围不同；[DPDK 后端文档](https://p4lang.github.io/p4c/dpdk_backend.html)则列出了 PSA/PNA 输入及尚不支持的功能。后端能接受某种架构的程序，不足以证明它实现了规范的每一种行为。

本教程保留 V1Model 作为主要实验架构。迁移是否值得，取决于实际目标与需求；验证工作除了改写接口，还包括报文内容、状态访问、控制平面和资源使用。

## 16.8 资源指引

- [PSA 1.2 规范](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PSA-v1.2.html)：核对报文路径、元数据初值、extern 与固定功能块。
- [p4c 的 BMv2 PSA 接口](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/p4include/bmv2/psa.p4)：对应本章实验所用编译器版本。
- [PNA 0.7 草案](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PNA-v0.7.html)：阅读 NIC 路径、主机接口与加速器模型。
- [p4c Tofino 后端](https://github.com/p4lang/p4c/tree/main/backends/tofino)：阅读公开架构接口、编译器实现和资源映射代码。
- [Open P4Studio](https://github.com/p4lang/open-p4studio)：核对模型、驱动、示例和硬件部署的附加条件。

## 16.9 本章小结

PSA、TNA 和 PNA 分别从可移植交换机、Tofino 目标和 NIC 的角度定义数据平面接口。PSA 的 ingress/egress 重解析、默认丢弃和分路径元数据，是从 V1Model 迁移时首先需要处理的差异。TNA 还要求程序满足具体硬件的放置与状态操作限制。

架构接口、目标实现与控制平面应分别核对。语言层面的正确性是基础；完成编译、报文验证和资源检查后，才能判断程序是否适合目标环境。

## 16.10 学完之后

主正文之后，可以按需要继续阅读附录或扩展实验：

- [附录 A · core.p4 解析](../appendix/A-核心库core.p4解析.md)：回顾跨架构使用的核心接口。
- [附录 B · 术语表](../appendix/B-术语表.md)：对照英文规范与论文中的术语。
- [附录 C · 学习资源](../appendix/C-学习资源.md)：查找后续阅读材料。
- [附录 D · 常见问题](../appendix/D-常见问题.md)：按故障现象排查工具链与实验环境。
- [`examples/`](../examples)：为已有程序补充边界报文，或尝试迁移到已经具备运行条件的目标。
