# 11 · V1Model 架构详解

本章依据 [p4c 的 `v1model.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/p4include/v1model.p4) 和 [BMv2 `simple_switch` 文档](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/simple_switch.md)，说明处理块接口、标准元数据及特殊报文路径。本机验证使用 p4c 1.2.5.10 和 `simple_switch` 1.15.0。

接口声明用于阅读架构，已经包含 `v1model.p4` 时不应重复定义。涉及 `hdr`、`meta`、`sm` 的片段采用 11.7 节的命名；额外类型会在相应位置说明。

## 11.1 V1Model 概览

V1Model 是 BMv2 `simple_switch` 使用的架构。普通单播报文的处理顺序可概括为：

```mermaid
flowchart LR
    P[Parser] --> V[VerifyChecksum]
    V --> I[Ingress]
    I --> Q[复制与排队]
    Q --> E[Egress]
    E --> C[ComputeChecksum]
    C --> D[Deparser]
    D --> O[端口输出]
```

图中只画出正常继续处理的路径。解析或校验和失败会留下错误状态，由后续程序决定如何处理；Ingress 丢弃的报文不会继续进入 Egress。克隆、重提交、重循环等路径见 11.5 节。

| 可编程块        | 主要职责                                 |
| --------------- | ---------------------------------------- |
| Parser          | 提取报头、产生解析错误                   |
| VerifyChecksum  | 验证指定数据的校验和                     |
| Ingress         | 查表、修改报头、选择单播或多播等处理方式 |
| Egress          | 按已选定的出端口和报文副本执行处理       |
| ComputeChecksum | 更新输出所需的校验和                     |
| Deparser        | 按程序顺序输出有效报头                   |

复制、排队和调度由目标实现。P4 可以通过元数据选择相应行为，控制平面可以配置复制规则、队列深度或速率，但这些模块的内部调度算法并不是本章六个 P4 块的主体。

## 11.2 顶层 Package

`V1Switch` 接收六个处理块：

```p4
package V1Switch<H, M>(Parser<H, M> p,
                      VerifyChecksum<H, M> vr,
                      Ingress<H, M> ig,
                      Egress<H, M> eg,
                      ComputeChecksum<H, M> ck,
                      Deparser<H> dep);
```

它们都没有默认值或 `@optional` 标记，装配时必须全部提供：

```p4
V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
```

不需要某个 Control 执行操作时，可以保留接口并写空的 `apply`，不能省略这个构造实参。这里的构造调用发生在编译期；报文运行时的块调用由架构安排，见 [第 10 章](./10-架构与包.md)。

## 11.3 六个块的接口

### 11.3.1 Parser

```p4
parser Parser<H, M>(packet_in packet, out H hdr,
                    inout M meta, inout standard_metadata_t sm);
```

`packet` 提供输入字节，`hdr` 接收解析得到的报头。`out` 不表示所有字段都自动清零；报头的初始有效性和提取规则见 [第 6 章](./06-Parser解析器.md)。

用户元数据 `meta` 与标准元数据 `sm` 都是 `inout` 参数。架构可在特殊路径上保留部分元数据，因此 Parser 中的初始化也可能覆盖保留值，不能只看参数方向就假定每次都是一份全新的零值结构体。

### 11.3.2 VerifyChecksum

```p4
control VerifyChecksum<H, M>(inout H hdr, inout M meta);
```

这里调用 `verify_checksum` 或 `verify_checksum_with_payload`。检测到错误后，Ingress 可通过 `sm.checksum_error` 读取结果；错误不会自动终止程序或丢弃报文。该块本身没有独立的标准元数据参数。

### 11.3.3 Ingress

```p4
control Ingress<H, M>(inout H hdr, inout M meta,
                      inout standard_metadata_t sm);
```

Ingress 通常先检查解析和校验和结果，再查表并选择去向。普通单播使用 `sm.egress_spec`，多播使用 `sm.mcast_grp`。在本机 `simple_switch` 中，未赋值的 `egress_spec` 初始为 0；这意味着可能发往端口 0，而不是自动丢弃。

### 11.3.4 Egress

```p4
control Egress<H, M>(inout H hdr, inout M meta,
                     inout standard_metadata_t sm);
```

报文到达 Egress 时，出端口已经确定，可从 `sm.egress_port` 读取。多播和克隆产生的副本分别执行 Egress，适合按端口改写报头或区分副本。

**在 Egress 中把 `egress_spec` 改成另一个普通端口值，不会重新选路。** 本机仍向进入该次 Egress 时选定的端口发送。`egress_spec` 在这里还有丢弃用途：设为目标的丢包值可以丢弃当前副本。

### 11.3.5 ComputeChecksum

```p4
control ComputeChecksum<H, M>(inout H hdr, inout M meta);
```

这里调用 `update_checksum` 或 `update_checksum_with_payload`。它位于 Egress 之后、报头输出之前，因而能覆盖 Egress 对参与计算字段的修改。条件计算使用函数的第一个参数；不能把任意 Egress 逻辑搬入这个块。

### 11.3.6 Deparser

```p4
control Deparser<H>(packet_out packet, in H hdr);
```

`hdr` 为 `in` 参数，不能在这里修改报头。BMv2 要求使用顺序的 `emit` 调用，未解析负载由目标保留。

接口没有独立的用户元数据参数。需要把元数据传入报文时，应在前面的处理块中将选定值写入有效且已初始化的报头，再输出该报头，见 [9.9 节](./09-Deparser反解析器.md#99-哪些数据会出现在输出中)。

## 11.4 `standard_metadata_t` 速查

以下为本机头文件提供的字段。表中的“只读”指架构使用约定；整个结构体的参数方向仍是 `inout`，编译器不一定拒绝对只读字段的赋值。

| 字段                       | 类型／位宽 | 含义与使用位置                                                   |
| -------------------------- | ---------- | ---------------------------------------------------------------- |
| `ingress_port`             | `bit<9>`   | 普通入站报文的入端口，只读；特殊路径不能一概视为最初的物理入端口 |
| `egress_spec`              | `bit<9>`   | Ingress 选择单播端口；Ingress／Egress 都可用丢包值标记丢弃       |
| `egress_port`              | `bit<9>`   | 本次 Egress 的出端口，只读；不要在 Ingress 中依赖它              |
| `instance_type`            | `bit<32>`  | 当前处理阶段的实例类型，只读，见 11.6 节                         |
| `packet_length`            | `bit<32>`  | 当前报文实例的长度，单位为字节，只读                             |
| `enq_timestamp`            | `bit<32>`  | 入队时间戳，Egress 读取                                          |
| `enq_qdepth`               | `bit<19>`  | 入队时的队列深度，单位为报文数，Egress 读取                      |
| `deq_timedelta`            | `bit<32>`  | 排队时间，Egress 读取                                            |
| `deq_qdepth`               | `bit<19>`  | 出队时的队列深度，单位为报文数，Egress 读取                      |
| `ingress_global_timestamp` | `bit<48>`  | 入站时间戳，只读                                                 |
| `egress_global_timestamp`  | `bit<48>`  | 开始 Egress 处理的时间戳，Egress 读取                            |
| `mcast_grp`                | `bit<16>`  | Ingress 指定多播组，0 表示不请求多播                             |
| `egress_rid`               | `bit<16>`  | 多播复制节点的 replication ID，Egress 读取                       |
| `checksum_error`           | `bit<1>`   | 校验和验证失败时为 1，Ingress 读取                               |
| `parser_error`             | `error`    | Parser 的错误结果；无错误时为 `error.NoError`                    |
| `priority`                 | `bit<3>`   | 入队时选择优先级队列                                             |

队列和时间戳字段通过头文件中的 `@alias` 对应到 BMv2 内部字段。应直接使用随工具链提供的定义，不要复制一份删掉注解的 `standard_metadata_t`。本机定义中没有 `lf_field_list` 字段。

较新的 `V1MODEL_VERSION` 分支用 `PortId_t` 表示三个端口字段；本机头文件中它仍是 `bit<9>` 的别名。版本宏还会影响部分 extern 接口，不能把宏值当作独立于头文件版本的兼容性保证。

### 11.4.1 长度、时间戳与队列

普通入站报文的 `packet_length` 来自交给 BMv2 的报文字节数。抓包是否包含 Ethernet FCS 取决于收发路径，不能仅凭该字段推断。修改报头有效位或协议长度字段，也不等于这个元数据会立即变成最终序列化长度。

本机时间戳和排队时长以微秒计。全局时间戳以进程启动附近的时间为基准，不是 Unix 时间；定宽字段会回绕。队列深度以报文数计，不是字节数。

`simple_switch` 默认每个端口只有一个优先级队列。使用多个队列时，启动参数形如 `--priority-queues 3`，放在目标参数分隔符 `--` 之后。此时合法优先级为 0、1、2，数值越大优先级越高；本机对超出已配置队列范围的报文会丢弃。仅给 `priority` 赋非零值，不会自动创建队列。

### 11.4.2 出端口、多播与丢弃

丢包端口默认是 511，可以通过 `--drop-port` 修改。程序宜调用 `mark_to_drop(sm)`，避免把 511 固定写入通用逻辑。

非零 `mcast_grp` 请求按控制平面配置的组进行复制。它不是输出端口，也不保证一定产生副本：组及复制节点必须有效。`egress_rid` 来自复制节点配置，不等于端口号，同一个节点发往多个端口时可以使用同一个 RID。

## 11.5 常用 extern 函数

### 11.5.1 `mark_to_drop`

```p4
extern void mark_to_drop(inout standard_metadata_t standard_metadata);
```

该调用设置目标的丢包值并清零 `mcast_grp`，但不终止后续代码。后续赋值仍可能改变结果；要停止当前控制调用链，可在调用后执行 `exit`，见 [7.7 节](./07-控制块与动作.md#77-noaction-与-mark_to_drop)。

已经请求的克隆或重提交还有各自的处理规则，不能把这个函数理解为撤销当前报文的一切副作用。

### 11.5.2 校验和验证与更新

两个接口的第三个参数方向不同：

```p4
extern void verify_checksum<T, O>(in bool condition, in T data,
                                  in O checksum, HashAlgorithm algo);
extern void update_checksum<T, O>(in bool condition, in T data,
                                  inout O checksum, HashAlgorithm algo);
```

`verify_checksum` 读取报头中已有的校验和值，并通过架构错误状态报告结果；`update_checksum` 将计算结果写回。条件为 `false` 时，前者不进行这次验证，后者不修改输出字段。不能依靠一次条件为假的验证去清除先前的校验和错误。

按接口约束，`data` 是由 `bit<W>`、`int<W>` 或 `varbit<W>` 字段组成的元组，总位宽须为校验和值位宽的整数倍；校验和字段为 `bit<X>`。算法参数须为编译期常量，支持的算法与位宽还受目标约束。`HashAlgorithm` 枚举中出现一个名字，并不代表所有目标都支持对应的校验和配置。

IPv4 固定报头使用 `csum16`，参与计算的数据按报头顺序排列，并排除原 `hdrChecksum` 字段，完整代码见 11.7 节。IHL 大于 5 时还要覆盖选项，不能直接套用固定报头元组。

带 `_with_payload` 后缀的接口会再纳入 Parser 未解析的字节。这里的“负载”由 Parser 消耗了多少字节决定，不自动等同于某个协议长度字段规定的数据范围；计算 TCP／UDP 校验和时仍需安排伪首部、字段和实际覆盖长度。

### 11.5.3 `hash`

```p4
extern void hash<O, T, D, M>(out O result, in HashAlgorithm algo,
                             in T base, in D data, in M max);
```

下面片段可放在 Ingress 的 `apply` 中；调用前应确保 Ethernet 报头有效：

```p4
bit<32> bucket;
hash(bucket, HashAlgorithm.crc32, 32w0,
     { hdr.ethernet.src, hdr.ethernet.dst }, 32w8);
```

结果落在 0 到 7 之间。一般而言，`max >= 1` 时结果范围为 `[base, base + max - 1]`；`max == 0` 时结果为 `base`。应选择足以容纳结果的位宽，并保证参与计算的字段已初始化。

### 11.5.4 `random`

```p4
extern void random<T>(out T result, in T lo, in T hi);
```

`T` 为 `bit<W>`，结果取自包含两个端点的区间 `[lo, hi]`。`lo > hi` 时，接口未规定结果。不要把这个接口视为密码学随机数来源。

### 11.5.5 `clone` 与元数据保留

```p4
extern void clone(in CloneType type, in bit<32> session);
extern void clone_preserving_field_list(in CloneType type,
                                        in bit<32> session, bit<8> index);
```

`session` 是镜像会话标识，需由控制平面预先配置。例如，在已绑定端口 3 的实验中，向 `simple_switch_CLI` 输入以下命令，将会话 100 的副本发往端口 3：

```text
mirroring_add 100 3
```

P4 程序再在 Ingress 调用 `clone(CloneType.I2E, 100)`。配置多播组的 `mc_*` 命令不能直接代替镜像会话配置；镜像会话也可以通过 `mirroring_add_mc` 关联一个已经配置好的多播组。

| 操作            | 调用位置 | 副本起点与报头内容                                                                          |
| --------------- | -------- | ------------------------------------------------------------------------------------------- |
| `CloneType.I2E` | Ingress  | 使用本轮 Parser 开始时的报文字节；BMv2 重新解析后进入 Egress，不执行用户 Ingress 的修改逻辑 |
| `CloneType.E2E` | Egress   | 使用该次 Egress 结束时的报头状态，再执行一次 Egress                                         |

原报文继续按自己的路径处理。未配置会话时不会产生对应副本；多次调用也不是每次都追加一组克隆请求，同一次 Control 执行中以最后一次请求的会话和字段列表为准。

`clone` 不保留用户元数据。需要保留字段时，把 `@field_list` 标在用户元数据的字段上，例如用下面的类型替换程序中的 `metadata` 声明：

```p4
struct metadata {
    @field_list(1)
    bit<9> original_port;
}
```

Ingress 可先设置 `meta.original_port = sm.ingress_port`，再调用 `clone_preserving_field_list(CloneType.I2E, 100, 1)`。保留的是该次 Ingress 结束时的字段值；E2E 对应 Egress 结束时的值。未列入的字段不能假定继续携带原值。

E2E 副本会再次执行 Egress，应根据 `instance_type` 等条件避免无界克隆。

### 11.5.6 `digest`

```p4
extern void digest<T>(in bit<32> receiver, in T data);
```

`digest` 在 Ingress 向控制平面报告选定数据，不等于转发一份完整报文。接口规定数据取调用时的值，与克隆保留元数据的取值时机不同。消息可能被批量处理，接收和确认方式取决于所用控制接口。

BMv2 的 V1Model 实现忽略 `receiver` 参数的数值，它不是用来选择镜像会话的 session ID。需要稳定的控制平面类型名称时，可以显式使用命名结构体作为 `T`。

### 11.5.7 重提交与重循环

当前接口使用字段列表索引：

```p4
extern void resubmit_preserving_field_list(bit<8> index);
extern void recirculate_preserving_field_list(bit<8> index);
```

| 操作                                | 调用位置 | 再次进入 Parser 的字节                                           |
| ----------------------------------- | -------- | ---------------------------------------------------------------- |
| `resubmit_preserving_field_list`    | Ingress  | 本轮解析开始时的原报文字节；Ingress 对报头的修改不进入这份字节流 |
| `recirculate_preserving_field_list` | Egress   | 经本轮校验和更新和 Deparser 输出后的报文字节                     |

它们都是在本轮处理结束时请求后续路径，不是从函数调用处立即跳回 Parser。`index` 为编译期确定的 `bit<8>` 值，选择用户元数据中标记为 `@field_list(index)` 的字段；保留值分别取自 Ingress 或 Egress 结束时。

旧的 `resubmit<T>(data)`、`recirculate<T>(data)` 已在本机头文件中标为弃用，不应写成无参数的 `resubmit()`、`recirculate()`。这些操作不产生正常端口输出后再从物理线缆收回的过程；报文在目标内部返回 Parser。

程序必须设置终止条件，例如检查进入 Ingress 时的实例类型，或使用保留的计数元数据限制次数。Parser 的初始化不能再无条件清掉这个计数。

### 11.5.8 多种请求同时出现时

本机 `simple_switch` 在 Ingress 结束时处理克隆和学习等副作用；原报文的去向按以下顺序选择：

1. 已请求重提交：返回 Parser。
2. 否则，`mcast_grp != 0`：按多播组复制。
3. 否则，`egress_spec` 为丢包值：丢弃。
4. 否则：向 `egress_spec` 指定的端口入队。

Egress 结束时先处理克隆，再判断原副本是否丢弃；未丢弃且请求重循环时，在反解析后返回 Parser，否则从既定端口输出。因此，丢弃原报文并不自动取消已请求的镜像副本，Ingress 中的重提交请求也不因随后调用 `mark_to_drop` 而消失。

详细顺序见 [BMv2 的处理伪代码](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/simple_switch.md#pseudocode-for-what-happens-at-the-end-of-ingress-and-egress-processing)。

## 11.6 `instance_type` 的取值与阶段

下表对应本机 [`SimpleSwitch::PktInstanceType`](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/targets/simple_switch/simple_switch.h)：

| 值  | 名称            | 主要含义                                                 |
| --- | --------------- | -------------------------------------------------------- |
| 0   | `NORMAL`        | 从端口进入的普通报文；也用于普通单播的 Egress 处理       |
| 1   | `INGRESS_CLONE` | I2E 克隆副本进入 Egress                                  |
| 2   | `EGRESS_CLONE`  | E2E 克隆副本进入 Egress                                  |
| 3   | `COALESCED`     | 源码枚举中的值；本章普通克隆、重提交和重循环路径不使用它 |
| 4   | `RECIRC`        | 重循环报文再次进入 Parser／Ingress                       |
| 5   | `REPLICATION`   | Ingress 多播复制后的 Egress 副本                         |
| 6   | `RESUBMIT`      | 重提交报文再次进入 Parser／Ingress                       |

这些名称不是本机 `v1model.p4` 自动提供的一组 P4 常量。程序需要比较时，应自行声明所用常量，而不要假定可直接引用源码中的 C++ 枚举名。

`instance_type` 描述当前阶段，不是永久的报文来源标签。本机实验中，值为 4 或 6 的报文再次完成 Ingress、选择普通单播后，进入 Egress 时已变为 0。若 Egress 还需要知道此前经历过重提交或重循环，应在 Ingress 将该信息写入用户元数据。

## 11.7 完整示例：固定 IPv4 路由实验

下面程序可保存为 `v1model-demo.p4`。它只接收无 VLAN、IHL 为 5 的 IPv4 报文，检查长度、解析错误、校验和和 TTL，再查一条固定路由：目的地址属于 `10.0.2.0/24` 时，从端口 2 输出，并改写两端 MAC、递减 TTL、更新 IPv4 校验和。

```p4
#include <core.p4>
#include <v1model.p4>

error { BadIPv4Version, UnsupportedIPv4Options, BadIPv4Length }

header ethernet_t {
    bit<48> dst;
    bit<48> src;
    bit<16> etherType;
}
header ipv4_t {
    bit<4> version;
    bit<4> ihl;
    bit<8> diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3> flags;
    bit<13> fragOffset;
    bit<8> ttl;
    bit<8> protocol;
    bit<16> hdrChecksum;
    bit<32> src;
    bit<32> dst;
}
struct headers {
    ethernet_t ethernet;
    ipv4_t ipv4;
}
struct metadata { }

parser MyParser(packet_in packet, out headers hdr,
                inout metadata meta, inout standard_metadata_t sm) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        verify(hdr.ipv4.version == 4, error.BadIPv4Version);
        verify(hdr.ipv4.ihl == 5, error.UnsupportedIPv4Options);
        verify(hdr.ipv4.totalLen >= 20, error.BadIPv4Length);
        verify((bit<32>)hdr.ipv4.totalLen <= sm.packet_length - 14,
               error.BadIPv4Length);
        transition accept;
    }
}
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(
            hdr.ipv4.isValid() && hdr.ipv4.ihl == 5,
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification,
              hdr.ipv4.flags, hdr.ipv4.fragOffset,
              hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}
control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t sm) {
    action drop() {
        mark_to_drop(sm);
    }
    action forward(bit<48> dst_mac, bit<48> src_mac, bit<9> port) {
        hdr.ethernet.dst = dst_mac;
        hdr.ethernet.src = src_mac;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        sm.egress_spec = port;
    }
    table ipv4_lpm {
        key = { hdr.ipv4.dst: lpm; }
        actions = { forward; drop; }
        const default_action = drop();
        const entries = {
            0x0a000200 &&& 0xffffff00: forward(0x020000000202, 0x020000000201, 2);
        }
    }
    apply {
        if (sm.parser_error != error.NoError || sm.checksum_error == 1) {
            drop();
            exit;
        }
        if (!hdr.ipv4.isValid()) {
            drop();
            exit;
        }
        if (hdr.ipv4.ttl <= 1) {
            drop();
            exit;
        }
        ipv4_lpm.apply();
    }
}
control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t sm) {
    apply { }
}
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid() && hdr.ipv4.ihl == 5,
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification,
              hdr.ipv4.flags, hdr.ipv4.fragOffset,
              hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}
control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
```

编译命令：

```bash
p4test --std p4-16 v1model-demo.p4
p4c-bm2-ss --std p4-16 --arch v1model -o v1model-demo.json v1model-demo.p4
```

绑定输入端口与端口 2 后即可测试，无需下发这条 `const entries` 路由。P4 源码中的前缀使用 `&&&` 掩码表达；这里不能把 `10.0.2.0/24` 的文本写法照搬成整数除法表达式。

需要运行双向路由实验时，可使用仓库的 [IPv4 路由示例](../examples/03-ipv4-router/README.md)。该例通过 Thrift 分别配置路由、下一跳 MAC 和出端口 MAC，动作及参数与本节的固定路由不同。其运行脚本会编译示例目录中的 `router.p4`，不会加载这里另存的 `v1model-demo.p4`。

| 输入条件                                            | 预期结果                                     |
| --------------------------------------------------- | -------------------------------------------- |
| 有效报文、TTL 大于 1、命中固定前缀                  | 输出端口 2，TTL 减 1，MAC 与 IPv4 校验和更新 |
| Ethernet／IPv4 被截断，或 IPv4 版本、长度不符合检查 | 丢弃                                         |
| IPv4 校验和错误                                     | 丢弃，不用重算校验和掩盖输入错误             |
| TTL 为 0 或 1                                       | 丢弃，避免无符号减法回绕                     |
| 路由未命中、非 IPv4、VLAN 或 IPv4 选项              | 丢弃                                         |

程序没有实现 ARP、ICMP 错误报告、邻居解析或完整的 IPv4 路由器行为。示例 MAC 地址和固定路由服务于实验，部署时需根据实际拓扑配置。未解析部分仍由 BMv2 保留；包括 Ethernet 填充在内的尾部字节不会仅因 `totalLen` 较小就自动裁掉。

本机已逐字节验证正常转发、TTL 边界、错误校验和、截断、长度不一致、路由未命中及填充保留等情况。修改 TTL 不影响 TCP／UDP 伪首部，因此本例只需更新 IPv4 报头校验和。

## 11.8 架构与实现边界

| 项目                 | 应如何理解                                                                                                            |
| -------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 六个顶层块           | Package 接口固定；Ingress／Egress 内仍可组织子 Control 和多张表，不能随意添加第七个架构阶段                           |
| 校验和位宽           | 接口为 `bit<X>`，不是统一限定为 16 位；本机已验证 `bit<32>` 配合 `crc32`                                              |
| 端口号               | 本机元数据为 9 位，可编码 0–511；还须考虑丢包值及实际绑定的接口。本机文件端口 300 已验证可用，不能概括为最多 256 端口 |
| Parser 长度接口      | 本机后端不支持 `packet_in.length()`；11.7 节使用普通入站路径的 `sm.packet_length`                                     |
| 校验和与 Deparser 块 | 可用语句受后端限制，不能按一般 Control 任意放表或条件处理                                                             |
| 性能与资源           | 软件目标的编译成功和功能正确，不代表硬件上的阶段、存储或线速要求已经满足                                              |

特殊路径对标准元数据的恢复还有实现细节。需要跨克隆、重提交或重循环保存原始入端口等信息时，应使用明确标记的用户元数据，并验证目标行为；不要依靠未经规定的字段初值。

## 11.9 本章小结

使用 V1Model 时，接口方向、元数据的有效阶段和报文路径需要一起检查。先处理解析与校验和错误，再安排转发和特殊请求；克隆、重提交和重循环既有不同的字节来源，也有不同的元数据保留时机。一次实验应同时核对实际输出端口、报头内容和副本数量。

## 11.10 下一步

[第 12 章](./12-外部对象Extern.md)进一步讨论计数器、计量器、寄存器等 extern 的接口、状态与并发语义。
