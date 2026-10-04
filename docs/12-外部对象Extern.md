# 12 · 外部对象 Extern

本章依据 P4₁₆ 1.2.5 规范、[本机 `v1model.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/p4include/v1model.p4) 及 [BMv2 实现说明](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/simple_switch.md)，讨论 extern 的接口、状态与调用约束。验证环境与第 11 章相同：p4c 1.2.5.10、`simple_switch` 1.15.0。

下文采用头文件默认的 `V1MODEL_VERSION=20180101`。报头名沿用 [11.7 节](./11-V1Model架构.md#117-完整示例固定-ipv4-路由实验)的 `hdr.ethernet`、`hdr.ipv4`，标准元数据名为 `sm`。除接口声明和明确标为全局的类型外，代码片段放在 Ingress 中；实例、动作和表位于声明区，调用语句位于 `apply` 或动作体中。

## 12.1 为什么需要 extern

普通局部变量不保存跨报文状态。例如，在 Control 中声明一个整数并递增，不能用它统计累计报文数。计数器、计量器和寄存器需要由目标管理持续存在的状态，P4 程序通过 extern 方法访问这些资源。

Extern 也可以提供无须实例化的函数，如 `hash`、`random`，或对外部系统产生影响的操作，如 `digest`。因此，不能把 extern 都理解为“内存数组”，也不能据此说 P4 程序完全无状态。表项和状态型 extern 的内容都可以跨报文保留。

接口声明规定名称、参数类型和方向；资源容量、操作语义及实现限制，需要结合核心库、架构和目标文档确定。

## 12.2 对象、函数与实例

下面是默认版本下 `counter` 的接口节选，已经包含 `v1model.p4` 时不要重复声明：

```p4
extern counter {
    counter(bit<32> size, CounterType type);
    void count(in bit<32> index);
}
```

构造函数与 extern 类型同名，没有返回类型；构造实参在编译期确定。实例化和方法调用分别写为：

```p4
counter(1024, CounterType.packets) flow_counter;
```

```p4
flow_counter.count(32w0);
```

实例声明不会在每个报文到来时重新分配一组计数器。方法调用才是报文处理期间发生的操作；大小写也必须与架构接口一致，`Counter` 不是 V1Model 中 `counter` 的别名。

Extern 函数则没有对象接收者，例如：

```p4
extern void random<T>(out T result, in T lo, in T hi);
```

`V1MODEL_VERSION >= 20200408` 时，三个索引型对象增加了索引类型参数。对应的声明形式为 `counter<bit<32>>(...)`、`meter<bit<32>>(...)`、`register<bit<32>, bit<32>>(...)`；最后一个例子依次指定元素类型和索引类型。切换版本宏时，应同时检查所有实例和调用。

## 12.3 V1Model 的常用 extern

| 接口                                                                  | 主要用途                           |
| --------------------------------------------------------------------- | ---------------------------------- |
| `counter`、`direct_counter`                                           | 按索引或匹配表项统计报文数、字节数 |
| `meter`、`direct_meter`                                               | 按配置的速率和突发量返回颜色       |
| `register`                                                            | 读写跨报文保存的数组元素           |
| `hash`、`random`                                                      | 哈希计算、随机数生成               |
| `verify_checksum`、`update_checksum` 及其 `_with_payload` 版本        | 验证或更新校验和                   |
| `digest`                                                              | 向控制平面报告选定字段             |
| `clone`、`clone_preserving_field_list`                                | 请求镜像副本                       |
| `resubmit_preserving_field_list`、`recirculate_preserving_field_list` | 请求重新处理报文                   |
| `mark_to_drop`                                                        | 设置当前路径使用的丢弃标记         |
| `action_profile`、`action_selector`                                   | 用于表的间接动作与成员选择         |

这些接口有不同的调用位置和控制平面配置方式。本章重点解释前三组状态型对象；特殊报文路径的执行顺序见第 11 章。

## 12.4 `counter`：按调用位置计数

### 12.4.1 声明与调用

以下片段假定用户元数据包含已赋值的 `bit<32> flow_id`：

```p4
counter(1024, CounterType.packets_and_bytes) my_counter;

action count_hit() {
    my_counter.count(meta.flow_id);
}
```

`size` 是元素个数，合法索引为 0 到 1023。接口规定越界调用不更新计数，但程序仍宜在调用前检查索引或通过有界哈希产生索引。

`CounterType.packets`、`bytes`、`packets_and_bytes` 分别选择包数、字节数或两者。一次 `count` 更新一次，重复调用会重复计数；计数单位是调用次数所对应的报文，而不是交换机替程序推断的“唯一报文”。

计数位置决定统计口径。先计数再丢弃，计数不会撤销；重提交后再次执行同一调用，也可能再次累加。本机字节计数采用当前报文实例记录的入站长度，不等于添加或删除报头后的最终输出长度。

### 12.4.2 控制平面访问

V1Model 的 `counter` 没有供 P4 程序读取数值的方法，也不能用 `count` 写入任意值。控制平面可通过目标提供的接口读取或重置计数，例如：

```text
counter_read MyIngress.my_counter 0
counter_reset MyIngress.my_counter
```

这是 `simple_switch_CLI` 的 Thrift 命令，名称须与编译产物中的对象名一致。使用 `simple_switch_grpc` 的 P4Runtime 接口时，应依据 P4Info 中的对象 ID 操作，两套接口的命令和标识不能直接互换；详见 [第 15 章](./15-P4Runtime控制平面.md)。

### 12.4.3 `direct_counter`：按匹配表项计数

直接计数器最多绑定一张表，不需要数据平面索引参数：

```p4
direct_counter(CounterType.packets) per_entry_ctr;

table count_by_protocol {
    key = { hdr.ipv4.protocol: exact; }
    actions = { NoAction; }
    counters = per_entry_ctr;
    size = 256;
    const default_action = NoAction();
}
```

在确认 IPv4 报头有效后调用 `count_by_protocol.apply()`。每次命中普通表项，V1Model 自动更新该表项的计数器；**不要求动作体显式调用 `per_entry_ctr.count()`**。本机即使在动作中写两次这个调用，一次表项命中仍只计一次。

命中执行 `NoAction` 的普通表项也会计数。表项未命中、转而执行默认动作时，本机没有对应的默认表项计数器；需要统计 miss 时，应另用索引型 `counter`，见 12.15 节。计数反映表项被命中，不保证报文最终成功输出。

## 12.5 `meter`：返回颜色，由程序决定处理方式

### 12.5.1 声明与调用

计量器根据速率和突发容量更新令牌桶状态，返回绿色、黄色或红色。它不会自动丢包，也不会替报文排队等待令牌。

```p4
meter(1024, MeterType.packets) per_flow_meter;
```

假定 `meta.flow_id` 为 `bit<32>`、`meta.pkt_color` 为 `bit<8>`，下面语句可放在 Ingress 的 `apply` 中：

```p4
if (meta.flow_id >= 1024) {
    mark_to_drop(sm);
    exit;
}
per_flow_meter.execute_meter(meta.flow_id, meta.pkt_color);
if (meta.pkt_color == 2) {
    mark_to_drop(sm);
    exit;
}
```

结果类型须为至少 2 位的 `bit<W>`。V1Model 用 0、1、2 分别表示绿、黄、红；头文件也提供 `V1MODEL_METER_COLOR_GREEN` 等宏。该方法没有输入颜色参数，`meta.pkt_color` 原值不参与计量。越界调用不更新 meter 状态，但结果值未规定，不能读取后继续作策略判断。

此例允许绿色和黄色报文继续处理，丢弃红色报文。若要修改 DSCP、统计超额流量或采用其他策略，需要另写相应逻辑。`MeterType.bytes` 按字节计量；本机采用报文实例的入站长度。

### 12.5.2 速率与单位

BMv2 的这组接口使用两个速率、三种颜色。控制平面配置承诺信息速率 CIR、峰值信息速率 PIR，以及对应的突发容量 CBS、PBS。下面的 CLI 命令为索引 0 配置两组“速率:突发量”：

```text
meter_set_rates MyIngress.per_flow_meter 0 0.001:10 0.002:20
```

对于本节的 packets meter，CIR 为每秒 1000 个报文、CBS 为 10 个报文，PIR 为每秒 2000 个报文、PBS 为 20 个报文。这里的 CLI 速率单位是**报文／微秒**，不是报文／秒。

| 配置接口                | packets meter 的速率单位 | bytes meter 的速率单位 |
| ----------------------- | ------------------------ | ---------------------- |
| `simple_switch_CLI`     | 报文／微秒               | 字节／微秒             |
| P4Runtime `MeterConfig` | 报文／秒                 | 字节／秒               |

突发容量分别以报文数或字节数表示。单位依据 [BMv2 CLI 文档](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/runtime_CLI.md#meter_set_rates)和 [P4Runtime 规范](https://p4.org/wp-content/uploads/sites/53/2024/10/P4Runtime-Spec-v1.4.1.html)。不要把 CLI 中的小数速率原样写入 P4Runtime 配置。

本机未配置的 meter 返回绿色；这不代表已经建立限速策略。验证时应明确配置参数，分别检查颜色和程序据此采取的操作，不能仅凭报文能通过就认为计量器有效。

### 12.5.3 `direct_meter`

直接计量器绑定表项，由 `read` 接收本次匹配产生的颜色：

```p4
direct_meter<bit<8>>(MeterType.packets) source_meter;

action read_source_color() {
    source_meter.read(meta.pkt_color);
}
table metered_sources {
    key = { hdr.ipv4.src: exact; }
    actions = { read_source_color; NoAction; }
    meters = source_meter;
    size = 1024;
    const default_action = NoAction();
}
```

确认 IPv4 报头有效后，可在 `apply` 中使用：

```p4
meta.pkt_color = 0;
if (metered_sources.apply().hit) {
    if (meta.pkt_color == 2) {
        mark_to_drop(sm);
        exit;
    }
}
```

本例只对命中表项的报文处理 meter 颜色，未命中时继续后续逻辑。表项速率需要由控制平面单独配置；Thrift CLI 使用表项句柄定位直接资源，P4Runtime 使用对应的表项描述。

本机后端要求至少一个表动作调用 `read`，且同一直接计量器的所有 `read` 调用必须写入同一个结果字段。实际计量发生在表项命中时，不能通过在另一个动作中省略 `read` 来跳过计量；本机也会将颜色写入配置好的字段。应把“计量是否发生”和“P4 程序怎样使用颜色”分开理解。

## 12.6 `register`：跨报文保存数据

### 12.6.1 元素类型与读写

```p4
register<bit<32>>(1024) pkt_count;
```

这声明 1024 个 32 位元素，索引为 0 到 1023。V1Model 接口文档规定的元素类型是 `bit<W>`；本机 p4c／BMv2 还支持 `int<W>`，但不支持直接把结构体作为元素类型。需要保存多个字段时，可以在一个位串中拼接编码，再用切片取回。

读取方法的实参顺序是“输出值、索引”，写入则是“索引、输入值”。下面动作要求调用者已经检查 `meta.flow_id < 1024`：

```p4
action increment_count() {
    bit<32> value;
    @atomic {
        pkt_count.read(value, meta.flow_id);
        value = value + 1;
        pkt_count.write(meta.flow_id, value);
    }
}
```

`bit<32>` 加法会按模 2³² 回绕，不会自动饱和。越界读的结果未规定，越界写不更新状态；不要把越界读当作返回零。

本机新建寄存器数组从零开始，也可以通过 `register_write` 设置实验初值。程序重载、状态恢复或控制平面重置后的内容应按实际操作确认，跨报文持久存在不等于跨进程重启持久保存。

### 12.6.2 原子性与 BMv2 的实现边界

语言规范要求对 extern 实例的单次方法调用具有原子性，但一次 `read` 和随后的一次 `write` 是两次调用。若两个报文都读到 10，再各自写入 11，就丢失了一次递增。需要保护整个读、改、写序列，而不能只看各方法是否原子。

上例在动作内部用 `@atomic` 标注这一序列。规范要求后端在无法实现指定原子性时拒绝程序；该要求不意味着任何目标都能执行任意大小的原子块。

**BMv2 `simple_switch` 并非单线程。** 本机实现有 Ingress、多个 Egress 及发送线程，并在一个动作执行期间锁住所访问的寄存器数组。因此，将读、改、写放在同一动作内时，寄存器操作可相对于访问相同数组的其他报文动作互斥。

这个保证来自 BMv2 的动作级寄存器锁，不能推广为所有目标上的动作都天然原子。本机对跨多个动作或多次表调用的 `@atomic` 块也没有提供更大的事务边界；仅编译通过不足以证明这类操作原子。实现说明见 [BMv2 register notes](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/simple_switch.md#bmv2-register-implementation-notes)。

### 12.6.3 适用范围

寄存器可保存计数、时间戳、状态位或流指纹，但仅有数组并不构成完整的流表或 NAT：仍要设计索引、冲突处理、有效位和老化机制。哈希到同一槽位的两个流不会自动分开。

控制平面读写能力也受实现限制。本机 Thrift 寄存器接口使用 64 位整数，不能因为 P4 侧能声明更宽元素，就假定 CLI 能无损读写任意位宽。控制平面若在流量运行期间重置状态，还需考虑与报文更新之间的协调。

## 12.7 `hash`

```p4
extern void hash<O, T, D, M>(out O result, in HashAlgorithm algo,
                             in T base, in D data, in M max);
```

V1Model 枚举包含 `identity`、`random`、`csum16`、`xor16`、`crc16`、`crc16_custom`、`crc32`、`crc32_custom`。具体调用仍须满足目标对算法、位宽和数据布局的限制。

假定 `meta.ecmp_hash` 为 `bit<32>`，下面在有效 IPv4 报头上选取 8 个桶之一：

```p4
if (hdr.ipv4.isValid()) {
    hash(meta.ecmp_hash, HashAlgorithm.crc32, 32w0,
         { hdr.ipv4.src, hdr.ipv4.dst, hdr.ipv4.protocol }, 32w8);
}
```

此例只用地址和协议号，不是五元组哈希。加入 TCP／UDP 端口前，必须先确认相应报头已成功解析且有效；非首片 IPv4 分片不能直接当作含有传输层报头。

设算法得到的值为 H：`max >= 1` 时结果为 `base + H % max`；`max == 0` 时为 `base`。输出位宽须能容纳结果。本机支持运行时的 `base`、`max`，桶数也不要求是 2 的幂。哈希用于分桶时允许碰撞，不能当作唯一流标识或密码学认证。

完整选路实验见仓库的 [ECMP 示例](../examples/05-ecmp/README.md)。它对 TCP／UDP 五元组计算哈希，并用两张普通表配置 ECMP 组与下一跳，没有使用 `action_selector`。该例明确拒绝所有 IPv4 分片，输入范围和验证方法以示例说明为准。

## 12.8 校验和接口

`verify_checksum` 只用于 `VerifyChecksum`，其校验和值参数为 `in`；`update_checksum` 只用于 `ComputeChecksum`，对应参数为 `inout`。验证失败通过 `checksum_error` 报告，由程序决定是否丢弃。

计算元组必须覆盖协议要求的字段，算法和结果位宽需要目标支持。带 `_with_payload` 后缀的接口还纳入 Parser 未解析的字节，并不会自动按 IPv4、TCP 或 UDP 的长度字段裁剪覆盖范围。完整声明和 IPv4 示例见 [11.5.2 节](./11-V1Model架构.md#1152-校验和验证与更新)。

V1Model 的旧 `Checksum16` 对象已弃用，只提供接收数据参数的 `get(data)`。VSS 的同名对象使用 `clear`、`update`、`remove` 和 `get()`，不能互换。两种接口的来源见 [6.12 节](./06-Parser解析器.md#612-parser-里的局部变量与实例)。

## 12.9 `digest`：向控制平面报告数据

典型用途是 MAC 学习：当源地址尚未登记时，上报源 MAC 和入端口，由控制平面决定如何更新学习表与转发表。`digest` 本身不会插入表项。

接口如下，仅能在 Ingress 调用：

```p4
extern void digest<T>(in bit<32> receiver, in T data);
```

BMv2 忽略 `receiver` 的数值，它不是镜像会话 ID。使用命名结构体有助于产生稳定的控制平面类型名称。先在程序全局声明：

```p4
struct mac_learn_t {
    bit<48> src_mac;
    bit<9> port;
}
```

再在 Ingress 声明动作和表：

```p4
action learn() {
    digest<mac_learn_t>(1, { hdr.ethernet.src, sm.ingress_port });
}
table smac_table {
    key = { hdr.ethernet.src: exact; }
    actions = { NoAction; learn; }
    size = 1024;
    const default_action = learn();
}
```

确认 Ethernet 报头有效后调用 `smac_table.apply()`；控制平面为已学习的源地址安装 `NoAction` 表项。接口规定 digest 数据取调用时的值，后续丢弃报文不会撤销该请求。

接收方仍需处理批量消息、重复通知和确认机制，具体过程取决于 Thrift 或 P4Runtime 实现。未知源地址持续到来时会反复触发默认动作，应结合数据平面策略和控制平面的处理能力安排上报。

## 12.10 克隆与元数据保留

在 Ingress 调用 `clone(CloneType.I2E, 100)`，请求按会话 100 创建镜像副本；E2E 克隆则在 Egress 请求。会话必须事先配置，例如：

```text
mirroring_add 100 3
```

这将会话 100 的副本送往已绑定的端口 3。多播组配置不能直接替代镜像会话配置。

普通 `clone` 不保留用户元数据。需要保留原入端口时，在程序全局的用户元数据类型中标注相应字段：

```p4
struct metadata {
    @field_list(1)
    bit<9> original_in_port;
}
```

在普通入站路径的 Ingress 设置 `meta.original_in_port = sm.ingress_port`，再调用 `clone_preserving_field_list(CloneType.I2E, 100, 1)`。保留值取自该次 Ingress 结束时，E2E 则取自 Egress 结束时；报文字节来源与递归克隆限制见 [11.5.5 节](./11-V1Model架构.md#1155-clone-与元数据保留)。

## 12.11 重提交与重循环

| 接口                                   | 调用位置 | 重新送入 Parser 的内容                              |
| -------------------------------------- | -------- | --------------------------------------------------- |
| `resubmit_preserving_field_list(1)`    | Ingress  | 本轮解析开始时的报文字节，不含 Ingress 对报头的修改 |
| `recirculate_preserving_field_list(1)` | Egress   | 本轮校验和更新和反解析之后的报文字节                |

索引 1 选择用户元数据中带有 `@field_list(1)` 的字段。请求在相应处理阶段结束后生效，不是从函数调用处立即跳回 Parser；实际去向还取决于丢弃、多播等请求的优先顺序。

程序必须限制再次处理的次数，并避免 Parser 无条件清掉保留的循环计数。不要仅因重提交路径较短，就给出不依赖程序和目标的性能结论。详细规则见 [11.5.7 节](./11-V1Model架构.md#1157-重提交与重循环)。

## 12.12 `random`

```p4
bit<16> sample;
random(sample, 16w0, 16w100);
```

结果范围包含 0 和 100，共 101 个整数。接口要求类型为 `bit<W>`；`lo > hi` 时结果未规定。本机实现允许运行时上下界，位宽上限为 64 位。它可用于实验采样，但不应作为密码学随机源；需要精确概率时，还应检查目标的分布保证和采样条件。

## 12.13 自定义 extern 的实现边界

仅在 P4 文件中增加 extern 声明，不会让目标自动具备相应功能。通常还需要编译器能识别或保留该接口，并由目标提供实现；软件目标可以用宿主语言实现，硬件目标也可能映射到专门电路。不能概括为所有目标都必须用 C/C++ 编写。

语言还允许 extern 声明 `abstract` 方法，并由 P4 程序在实例化时提供这些方法的实现。这是接口明确提供的扩展点，不意味着可以用 P4 重写任意 extern 的底层行为；目标是否支持仍须检查。

BMv2 的 [custom_extern 示例](https://github.com/p4lang/behavioral-model/tree/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/examples/custom_extern)展示了一种实现路径：

1. 在 P4 中声明对象或函数接口。
2. 用 C++ 实现并通过 BMv2 的注册宏登记，编译为共享库。
3. 使用 `p4c-bm2-ss --emit-externs` 生成保留相应 extern 信息的 JSON。
4. 启动 `simple_switch` 时，在目标参数分隔符 `--` 后使用 `--load-modules=路径/definition.so` 加载共享库。

这种方式不要求每次都重新编译整个 BMv2。更复杂的参数映射或硬件实现可能还需后端支持；应以目标的扩展接口为准。

## 12.14 语言、架构与目标各自规定什么

语言规范规定 extern 声明、类型检查、参数传递、实例化和基本并发规则，核心库也规定部分 extern 的语义。具体计数、计量、寄存器及复制行为由架构接口进一步定义，目标再给出支持范围和资源限制。因此，extern 不是完全没有语义的“占位符”。

移植时应逐项比较接口、位宽、索引范围、初始化、原子性和控制平面表示。同名接口不保证同义；使用 PSA 等标准架构可以减少差异，但仍须检查目标支持的特性与容量。

## 12.15 综合示例：带命中统计的 IPv4 ACL

下面的 Control 可直接替换 [11.7 节完整程序](./11-V1Model架构.md#117-完整示例固定-ipv4-路由实验)中的 `MyIngress`，其余类型和处理块保留。先检查输入，再执行 ACL；允许的报文继续查固定路由，拒绝和未命中的报文丢弃。ACL 只匹配 IPv4 地址和协议号，不读取传输层端口。

本节与仓库 [ACL 示例](../examples/04-acl/README.md)都演示命中计数，但策略和转发方式不同：

| 项目         | 本节 `extern-acl.p4`                                 | 编号示例 04                      |
| ------------ | ---------------------------------------------------- | -------------------------------- |
| ACL 键       | 源、目的 IPv4 地址为三元匹配，协议号为精确匹配       | 五元组，五个字段均为三元匹配     |
| ACL 未命中   | 默认拒绝，记录 `acl_miss[0]`                         | 默认允许，同样记录 `acl_miss[0]` |
| 允许后的处理 | 查固定 IPv4 路由，改写 MAC、递减 TTL 并更新校验和    | 查静态二层表，保持报文字节不变   |
| IPv4 分片    | 只按 IPv4 报头中的地址和协议号过滤，不检查传输层端口 | 在查询 ACL 前拒绝首片和后续片    |

两例的动作名、匹配字段和拓扑配置应分别使用，不能直接混用 CLI 命令。下面的代码和命令均针对本节程序。

```p4
control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t sm) {
    direct_counter(CounterType.packets_and_bytes) acl_ctr;
    counter(1, CounterType.packets_and_bytes) acl_miss;
    bool permitted;

    action acl_permit() { permitted = true; }
    action acl_drop() { permitted = false; }
    table acl {
        key = {
            hdr.ipv4.src: ternary;
            hdr.ipv4.dst: ternary;
            hdr.ipv4.protocol: exact;
        }
        actions = { acl_permit; acl_drop; }
        counters = acl_ctr;
        size = 512;
        const default_action = acl_drop();
    }
    action drop() { mark_to_drop(sm); }
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
        permitted = false;
        if (!acl.apply().hit) {
            acl_miss.count(0);
        }
        if (!permitted) {
            drop();
            exit;
        }
        ipv4_lpm.apply();
    }
}
```

将组合后的完整程序保存为 `extern-acl.p4`，编译：

```bash
p4test --std p4-16 extern-acl.p4
p4c-bm2-ss --std p4-16 --arch v1model -o extern-acl.json extern-acl.p4
```

交换机启动并绑定输入端口和端口 2 后，向 `simple_switch_CLI` 输入以下命令。第一条允许指定子网间的 UDP，第二条以更高优先级拒绝源地址 `10.0.1.9`：

```text
table_add MyIngress.acl MyIngress.acl_permit 10.0.1.0&&&255.255.255.0 10.0.2.0&&&255.255.255.0 17 => 10
table_add MyIngress.acl MyIngress.acl_drop 10.0.1.9&&&255.255.255.255 10.0.2.0&&&255.255.255.0 17 => 5
```

CLI 命令末尾的 10 和 5 是表项优先级，数值较小者优先，因此重叠时拒绝规则获选。这与 P4Runtime 的数值方向不同，见 [8.8 节](./08-匹配动作表.md#88-表项优先级)。

记录每次 `table_add` 返回的表项句柄。新建空表的本机实验中，两条规则分别得到 0、1，可据此读取直接计数器；miss 使用独立索引 0：

```text
counter_read MyIngress.acl_ctr 0
counter_read MyIngress.acl_ctr 1
counter_read MyIngress.acl_miss 0
```

| 输入条件                                             | 处理结果与统计                                        |
| ---------------------------------------------------- | ----------------------------------------------------- |
| 有效 UDP，源 `10.0.1.1`、目的 `10.0.2.2`、TTL 大于 1 | 命中允许规则，更新该表项计数；从端口 2 转发，TTL 减 1 |
| 同上，但源地址为 `10.0.1.9`                          | 命中拒绝规则，更新该表项计数后丢弃                    |
| 有效报文但没有匹配的 ACL 规则                        | 执行默认拒绝，更新 `acl_miss[0]`                      |
| 解析错误、校验和错误、非 IPv4 或 TTL 不足            | 在 ACL 前丢弃，不更新这三个 ACL 统计值                |

动作体没有显式的直接计数器调用，统计仍随表项命中自动更新。允许规则的计数表示通过 ACL 的次数，不是最终输出量；若之后路由未命中或后续阶段丢弃，ACL 计数仍然保留。继承的示例范围仍限于固定 IPv4 报头与固定路由，不实现 ARP、邻居解析或 ICMP 错误报告。

本机已验证重叠规则、默认拒绝、输入错误、分片和填充保留，并逐字节核对转发输出。另加一条指向路由未覆盖网段的允许规则后，也确认了 ACL 计数增加而报文仍被路由表丢弃的情况。

## 12.16 本章小结

使用状态型 extern 时，先确定状态属于数组索引还是匹配表项，再核对更新时机、结果有效性和并发边界。计数器记录经过指定位置的处理，计量器提供策略输入，寄存器保存程序自行维护的状态；它们都不能替程序补全流标识、丢弃策略或控制平面配置。

## 12.17 下一步

[第 13 章](./13-注解与高级特性.md)继续讨论注解、静态断言、泛型等特性，其中注解的语义需要与编译器和目标支持一起检查。
