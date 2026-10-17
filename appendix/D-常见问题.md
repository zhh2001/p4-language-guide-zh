# 附录 D · 常见问题与调试技巧

本附录按编译、交换机运行和控制接口分层排查。命令从仓库根目录执行，接口名、监听端口和 Python 解释器按实际拓扑替换。复核环境为 p4c `1.2.5.10`（`8b6de3c57`）、BMv2 `1.15.0-2bdd0b7b`。

语言规则依据 P4<sub>16</sub> v1.2.5，控制协议依据 P4Runtime v1.4.1。下文使用 V1Model 的 `simple_switch` 和提供 P4Runtime 服务的 `simple_switch_grpc`。完整环境检查见[第 1 章](../docs/01-环境搭建.md)，流水线启动与控制器示例分别见[第 14 章](../docs/14-BMv2编译与运行.md)和[第 15 章](../docs/15-P4Runtime控制平面.md)。

## D.1 编译期

### D.1.1 找不到 `core.p4` 或 `v1model.p4`

先确认调用的是哪一套编译器：

```bash
command -v p4c-bm2-ss
p4c-bm2-ss --version
```

本机源码安装的头文件位于 `/usr/local/share/p4c/p4include/`。若通过名为 `p4lang-p4c` 的 Debian 软件包安装，可用下面的命令查看该包记录的路径：

```bash
dpkg -L p4lang-p4c | rg '/(core|v1model)\.p4$'
```

确认目录中确有对应文件后，再增加搜索路径，例如：

```bash
mkdir -p build/appendix-d
p4c-bm2-ss --std p4-16 -I /usr/local/share/p4c/p4include \
    -o build/appendix-d/hello.json examples/01-hello/hello.p4
```

`-I` 增加头文件搜索目录。目录中缺少文件时，先补齐安装。存在多套工具链时，确认所选头文件与编译器版本及程序使用的架构配套。

### D.1.2 `verify` 无法调用

先检查是否包含 `core.p4`，以及参数是否为布尔条件和 `error` 值。核心库的 `verify` 只能在 Parser 中调用。本机在 Control 中调用时报告 `may only be invoked in parsers`。

V1Model 的 `VerifyChecksum` 是控制块，在其中使用架构提供的 `verify_checksum`。Ingress 可根据 `checksum_error` 或 `parser_error` 调用 `mark_to_drop`，丢弃标记与后续控制流的关系见 [D.2.2 节](#d22-日志出现-egress_spec--511)。

`verify` 失败会令 Parser 进入 `reject`，但是否丢包还取决于架构和后续处理。V1Model 中通常由 Ingress 检查 `parser_error`。接口说明见[附录 A](A-核心库core.p4解析.md)。

### D.1.3 实参不是左值

`out` 和 `inout` 参数需要写回结果，实参须为可写左值。不需要的 `out` 结果可以用 `_` 丢弃。例如下面的控制块在包含核心库后可通过语言检查：

```p4
control C(out bit<8> result) {
    action f(out bit<8> y) { y = 7; }
    apply {
        f(y = result);
    }
}
```

这里的 `y = result` 是**命名实参**，指定形参 `y` 对应的写回位置为 `result`。若改为 `f(y = 0)`，常量无法接收写回结果，编译器会报告左值错误。变量、可写字段和合法切片可作为写回位置，类型须与形参匹配。

### D.1.4 编译时的类型、位宽不匹配

根据诊断位置比较实参与形参、赋值两端或运算两侧的类型，再按语言的转换规则统一位宽。显式转换到较窄的类型时，需检查高位截断是否符合预期。

语言检查与控制平面编码应分开定位：`.p4` 文件编译时的类型错误查[第 5 章](../docs/05-类型系统.md)。程序已运行、下发表项时发生的字节串错误查 D.3.4。后者需要读取实际部署程序的 P4Info。

### D.1.5 语言检查通过，目标后端仍报错

`p4test` 主要检查语言与类型规则，`p4c-bm2-ss` 还要将程序转换成 BMv2 可执行的配置。若前者通过而后者失败，可从目标后端报告的操作或接口开始定位。

遇到动作数、表容量、表达式或资源相关错误时，保留完整编译命令和第一条有意义的诊断，确认错误来自前端、后端还是运行时表项插入。硬件目标还需结合编译报告检查流水线放置、PHV 和存储资源。

## D.2 运行期：BMv2

### D.2.1 发包后没有看到交换机处理

按入口路径逐项检查：

1. 发包程序是否运行在拥有该接口的网络命名空间中。
2. Linux 接口是否存在、启用，是否与 BMv2 的 `-i 端口号@接口名` 绑定一致。
3. 交换机是否成功加载本次编译的 JSON，进程是否仍在运行。
4. 入口抓包是否真的看到了预期帧，其长度和封装是否符合 Parser。

例如，第 14 章手工创建的交换机侧接口为 `p14s1`。使用 Mininet 拓扑时应换成实际的 `s1-eth1` 等名称：

```bash
ip -br link
ip -s link show dev p14s1
sudo ethtool -k p14s1
```

BMv2 `simple_switch` **可以使用端口 0**。本教程 V1Model 的端口字段为 9 位，普通转发端口须有实际接口绑定，并避开已配置的丢弃端口和 CPU 端口。

校验和卸载以及 GRO/GSO/TSO 可能影响抓包所见的校验和、长度和分段。先用 `ethtool -k` 查看状态，再按实验需要调整。发送侧抓包显示校验和未完成时，可结合接收侧抓包核对实际到达的字节。

### D.2.2 日志出现 `egress_spec = 511`

511 是本机 `simple_switch` 的**默认**丢弃端口，可通过目标参数 `--drop-port` 改变。`mark_to_drop` 将 `egress_spec` 设为当前丢弃值，并清除 `mcast_grp`。它本身不会终止控制流。

沿后续动作追踪到阶段结束，重点检查：

- 后续代码重新赋值 `egress_spec` 或 `mcast_grp`，可能改变处理结果。
- 将 `egress_spec` 设为 0 会选择端口 0。
- 请求克隆、重提交或多播时，还要按相应路径追踪副本。

本机实测中，调用 `mark_to_drop` 后再设置普通输出端口，报文仍可转发。将丢弃端口改为 509 后，绑定端口 511 也可正常输出。完整顺序见 [11.5.8 节](../docs/11-V1Model架构.md#1158-多种请求同时出现时)。

### D.2.3 CLI 找不到表或动作

先确认 Thrift 端口连接的是预期交换机，再检查实际加载的表。以仓库 L2 示例为例，先运行并保留拓扑：

```bash
sudo bash examples/02-l2-switch/run.sh --keep
```

然后在另一终端连接脚本打印的 Thrift 端口。默认端口为 9090：

```bash
simple_switch_CLI --thrift-port 9090
```

在 CLI 中执行：

```text
show_tables
table_info MyIngress.dmac
table_dump MyIngress.dmac
```

完全限定名便于消除歧义，但本机 CLI 也接受**唯一的名称后缀**，例如没有同名冲突时可使用 `dmac`。出现歧义、加载了旧 JSON、连错实例，或对象因未使用而被编译器消除，都可能导致名称不可用。默认运行不加 `--keep` 时，验证结束就会停止交换机，之后无法再连接该实例。

### D.2.4 修改 IPv4 字段后校验和不正确

先看实际输出字节，再依次检查更新条件、字段列表、字段顺序及最终报头长度。IPv4 校验和覆盖 IPv4 报头。带选项时不能只计算固定的 20 字节部分，见 [RFC 791 §3.1](https://www.rfc-editor.org/rfc/rfc791.html#section-3.1)。

下面沿用仓库[路由器示例](../examples/03-ipv4-router/router.p4)的字段名，计算 `version = 4`、`ihl = 5` 的固定 IPv4 报头校验和。其他格式需在前面的处理块中丢弃，或补齐其解析与校验和计算：

```p4
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid() && hdr.ipv4.version == 4 && hdr.ipv4.ihl == 5,
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.src, hdr.ipv4.dst },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}
```

`update_checksum` 对给定数据计算校验和并写回结果。这里的元组**没有包含 `hdrChecksum`**，因此原校验和值不参与计算，无需先将它置零。条件为 `false` 时，输出字段保持原值。

V1Model 的 `verify_checksum` 失败会设置 `checksum_error`，由后续逻辑决定是否丢弃。TCP/UDP 有各自的校验和，修改 IP 地址或传输层字段时，也要按其覆盖范围更新。

### D.2.5 新增 VLAN 没有正确出现在报文中

检查报头是否有效、各字段是否初始化，以及 Deparser 是否按正确位置调用了 `emit`。还需更新外层以太网的 EtherType，并在 VLAN 头中填写原来的内层类型。

`setValid()` 设置有效位，字段需要另行赋值。Deparser 会跳过无效报头，删除 VLAN 标签时应同时恢复外层 EtherType。完整示例见[第 9 章](../docs/09-Deparser反解析器.md)。

### D.2.6 报文没有从预期端口发出

先读回转发表项，再沿日志检查是否命中、执行了哪个动作，以及 Egress 是否又修改了报头或标记丢弃。核对 Linux 接口绑定与输出端口的对应关系，最后在接收端抓包确认。

BMv2 允许将普通报文从入端口发回，[Hello P4 示例](../examples/01-hello)就是这样做的。仓库 L2 示例在 Egress 主动丢弃输出端口等于入端口的报文，这是程序采用的回源过滤策略。检查反射时，在同一接口分别捕获进入交换机和由交换机发出的帧。

若程序使用 `recirculate`，还需追踪报文重新进入 Parser 后的处理。

### D.2.7 修改配置文件后没有生效

编辑本地 `.p4`、JSON 或 CLI 命令文件，不会自动改变运行中的交换机。

| 修改内容              | 应采取的操作                                                           |
| --------------------- | ---------------------------------------------------------------------- |
| 已有表的表项          | 通过对应控制接口写入，并读回确认。通常无需重启交换机                   |
| `.p4` 源码            | 重新编译，再安装新的流水线配置。使用 P4Runtime 时同步更新配套的 P4Info |
| `commands.txt` 等文件 | 将命令实际提交给正确实例的 CLI，并检查每条命令的结果                   |

仓库编号示例的 `run.sh` 每次都会重新编译源码并启动新实例。02~05 的 `runtime/s1-commands.txt` 按新实例编写，加载前需过滤注释和空行。重复加载可能因表项或多播对象已存在而失败，修改运行中的表项时应使用相应的修改或删除命令，并读回确认。

`simple_switch` 的 JSON 切换涉及 `--enable-swap`、`load_new_config_file` 和 `swap_configs`。P4Runtime 使用独立的流水线配置 RPC，其中 `VERIFY_AND_COMMIT` 会清除原转发状态。单条表项的修改通过 CLI 或 P4Runtime `Write` 完成。

## D.3 P4Runtime

### D.3.1 写操作提示不是主控

先查看 `StreamChannel` 中的仲裁响应，再核对写入 RPC 的状态。P4Runtime v1.4.1 要求非主控写操作返回 `PERMISSION_DENIED`。

检查设备 ID、角色和选举 ID 是否一致，是否收到该连接的成功仲裁响应，以及请求流和接收循环是否仍保持。主控身份会变化，需要持续处理仲裁消息。规范还涉及服务端记录的历史最高选举 ID，详见[第 15 章主备说明](../docs/15-P4Runtime控制平面.md#158-多控制器与主备)。

同一设备、同一角色的选举 ID 由控制系统协调分配。

### D.3.2 匹配类型或表项格式被拒绝

用当前 P4Info 的 `table_id`、`field_id` 和匹配种类逐一检查请求：

| 匹配种类            | 常见错误                                             |
| ------------------- | ---------------------------------------------------- |
| `exact`             | 错用了 `lpm` 等消息分支，或遗漏必需字段              |
| `lpm`               | 前缀长度越界、前缀之外仍有非零位。全通配应省略该字段 |
| `ternary`           | 掩码为 0 的位置仍设置了值。全通配应省略该字段        |
| `range`、`optional` | 消息分支或通配表示与规范不符                         |

还要检查优先级和默认表项规则。含 `ternary`、`range` 或 `optional` 键的普通表项需要正整数优先级，P4Runtime 中数值较大者优先。默认表项使用空匹配列表、优先级 0，并通过 `MODIFY` 更新。

批量 `Write` 失败时应读取 trailing metadata 中的 `grpc-status-details-bin`。本机逐项的 `INVALID_ARGUMENT` 等错误可能包在外层 `UNKNOWN` 中。仅打印外层状态会漏掉具体原因，错误结构与定位方法见 [15.9 节](../docs/15-P4Runtime控制平面.md#159-错误处理与常见陷阱)。

### D.3.3 收不到 `PacketIn`

针对本教程的 `simple_switch_grpc`，按以下路径检查：

1. gRPC 连接、仲裁与持续接收循环是否正常。流水线是否已成功安装。
2. 启动参数 `--cpu-port` 是否与 P4 程序一致，并避开丢弃端口。
3. 数据平面是否真的将目标报文或副本送到 CPU 路径。普通转发不会自动上送。
4. 若程序使用 `@controller_header("packet_in")`，对应头是否已设置有效、初始化字段并按正确顺序输出，且 P4Info 元数据布局与程序一致。
5. 客户端是否识别 `StreamMessageResponse.packet`，并根据 `metadata_id` 解码，而不是假定固定的数组下标。

完整配置与收发示例见[第 15 章 Packet I/O](../docs/15-P4Runtime控制平面.md#156-packetinpacketout-与计数器实验)。

### D.3.4 `bit<9>` 是否必须编码成两字节

对普通的 `bit<W>` 字段，P4Runtime 使用大端字节串，canonical 表示是能容纳该值的最短非空字节串：

| 数值 | `bit<9>` 的 canonical 表示 |
| ---- | -------------------------- |
| 0    | `b"\x00"`                  |
| 1    | `b"\x01"`                  |
| 256  | `b"\x01\x00"`              |
| 511  | `b"\x01\xff"`              |

规范要求接收方接受数值等价的前导零扩展，例如 `b"\x00\x01"` 表示 1。空串无效，`b"\x02\x00"` 表示 512，超出 9 位范围。对端口字段，还要检查接口绑定及丢弃、CPU 端口约定。

字段位宽及 ID 从 P4Info 读取。使用 P4Runtime 类型翻译时，按翻译后的控制平面类型编码。规范条款见 [Bytestrings](https://p4lang.github.io/p4runtime/spec/v1.4.1/P4Runtime-Spec.html#sec-bytestrings)。

## D.4 调试方法

### D.4.1 打开 BMv2 日志

先在正确的交换机启动命令上添加 `--log-console --log-level trace`。下面以已建立第 14 章手工拓扑、尚未启动交换机为前提，运行原路反射示例：

```bash
mkdir -p build/appendix-d
p4c-bm2-ss --std p4-16 -o build/appendix-d/hello.json \
    examples/01-hello/hello.p4
sudo simple_switch --device-id 24 --thrift-port 9090 \
    --log-console --log-level trace \
    -i 1@p14s1 -i 2@p14s2 build/appendix-d/hello.json
```

确认编译成功后再启动交换机。已有实例时，在其启动命令中增加日志参数并重启。上面的命令在前台运行，完成后用 Ctrl+C 停止。

需要写文件时，将 `--log-console` 换成 `--log-file build/appendix-d/switch.log --log-flush`，保留所需的日志等级。本机生成的文件名为 `switch.log.txt`，`--log-flush` 使日志及时写入文件。

### D.4.2 在正确的位置抓包

以第 14 章手工拓扑中从端口 1 转发到端口 2 的报文为例，在两个终端分别运行：

```bash
mkdir -p build/appendix-d
sudo tcpdump -ni p14s1 -Q in -s 0 -w build/appendix-d/in.pcap
```

```bash
sudo tcpdump -ni p14s2 -Q out -s 0 -w build/appendix-d/out.pcap
```

这里的方向相对于抓包所在的 Linux 接口。反射实验应在同一接口分别观察进出方向。使用 Mininet 拓扑时换成实际接口名，抓主机侧接口则需进入对应主机命名空间。部分平台不支持 `-Q`，应结合接口、源地址和负载区分方向。

用 MAC、IP、协议字段和可辨认的负载关联同一帧，再比较修改字段与校验和。若接收接口已有报文而应用没有响应，继续检查主机协议栈及应用的接收情况。

### D.4.3 用 Scapy 构造可识别的报文

下面用于第 14 章的 Mininet L2 实验。先用 `mkdir -p build/appendix-d` 创建目录，再将脚本保存为 `build/appendix-d/send_probe.py`：

```python
from scapy.all import Ether, IP, UDP, Raw, sendp

packet = (
    Ether(src="02:00:00:00:00:01", dst="02:00:00:00:00:02")
    / IP(src="10.14.0.1", dst="10.14.0.2", ttl=64)
    / UDP(sport=1234, dport=9000)
    / Raw(b"appendix-d-probe")
)
sendp(packet, iface="h1-eth0", count=5, inter=0.1, verbose=False)
```

在从仓库根目录启动的 Mininet CLI 中执行：

```text
h1 python3 build/appendix-d/send_probe.py
```

该解释器须已安装 Scapy。`sendp` 按指定接口和目的 MAC 进行二层发送，使用其他拓扑时同步修改地址与接口。

从 PCAP 解析出的报文通常保留了原校验和值，修改后可删除受影响层的 `chksum` 字段，让 Scapy 在序列化时重新计算。负载长度改变时，还需更新或清除 `IP.len`、`UDP.len` 等长度字段。本机 Scapy 2.5.0 的 [IP、TCP、UDP 序列化实现](https://github.com/secdev/scapy/blob/v2.5.0/scapy/layers/inet.py)在 `chksum` 为 `None` 时自动计算相应校验和。

### D.4.4 定位“有入口包，没有出口包”

沿同一帧报文逐段检查：

| 位置              | 应核对的事实                                         |
| ----------------- | ---------------------------------------------------- |
| 入口              | 接口、端口号、报文字节与长度是否正确                 |
| Parser            | 提取是否完成，`parser_error` 和有效位是否符合预期    |
| Ingress           | 匹配键、命中结果、执行动作及输出元数据               |
| 复制与排队        | 是否请求多播、克隆或重提交，相关控制平面对象是否存在 |
| Egress            | 是否再次标记丢弃，输出报头是否被修改                 |
| 校验和与 Deparser | 更新条件、字段范围、有效位与输出顺序                 |
| 出口及主机        | 实际绑定接口是否发出，接收端是否接受                 |

日志字段和措辞随版本、路径及日志等级变化。`Recirculating packet` 只与重循环路径有关，普通单播没有这一行是正常的。需要区分并发报文时，可给测试帧添加不同负载，并结合日志中的报文标识追踪。

### D.4.5 查看 p4c 的中间结果

本机使用 `--dump` 指定目录，以 `--top4` 选择处理阶段。例如：

```bash
mkdir -p build/appendix-d/dump
p4c-bm2-ss --std p4-16 \
    --dump build/appendix-d/dump --top4 FrontEndLast \
    --toJSON build/appendix-d/hello.ir.json \
    -o build/appendix-d/hello.json examples/01-hello/hello.p4
```

`--top4 FrontEndLast` 输出匹配该阶段名称的 P4 表示。`--toJSON` 输出编译器中端后的 IR。`hello.ir.json` 用于编译器调试，运行 BMv2 应加载 `-o` 生成的 `hello.json`。阶段名与参数以所装版本的 `--help` 为准。

只检查头文件展开时，也可使用：

```bash
p4c-bm2-ss --std p4-16 -E examples/01-hello/hello.p4 \
    > build/appendix-d/hello.preprocessed.p4
```

本机该命令输出完整的预处理结果，标准错误为空，退出码为 1。这里用它查看头文件展开内容，程序是否有效仍通过完整编译确认。

## D.5 容易混淆的代码语义

### D.5.1 写字段不会自动使报头有效

给无效报头的字段赋值后，其有效位仍为 `false`，Deparser 会跳过该报头。构造新报头时，先调用 `setValid()`，再初始化所有将输出的字段。

成功的 `extract` 会设置有效位，整份报头赋值会复制源报头的有效性。读取无效报头字段所得的值未规定，详见[第 5 章](../docs/05-类型系统.md)。

### D.5.2 报头相等比较包含有效性

同一报头类型的两个值可以使用 `==`、`!=` 比较：

- 两者均无效时相等，不比较字段内容。
- 仅一者有效时不相等。
- 两者均有效时，所有对应字段都相等才算相等。

`hdr.ipv4 == hdr.ipv4_backup` 按上述规则同时考虑有效性与字段内容。

### D.5.3 `hash` 的 `max` 是输出范围大小

对 V1Model 的 `hash`，当 `max > 0` 且输出位宽足够时，结果位于 `[base, base + max - 1]`。`max = 0` 时返回 `base`。

若 `base = 0`、`max = 10`，结果为 0~9，用作数组索引时只会访问前 10 个槽。希望覆盖 1024 个槽时，应调整范围，并让查表、数组容量和控制平面配置保持一致。范围决定可选槽位，实际分布还取决于哈希算法与输入数据，见[第 12 章](../docs/12-外部对象Extern.md)。

### D.5.4 匹配字段顺序取决于控制接口

| 接口                | 字段如何对应                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------ |
| `simple_switch_CLI` | 按加载的 JSON 中的键顺序解释位置参数，可先用 `table_info` 查看                             |
| P4Runtime           | 通过 `field_id` 识别匹配字段，通过 `param_id` 识别动作参数。消息列表不要求照抄源码声明顺序 |

CLI 中交换两个同位宽的匹配值，可能被正常接受，却写成另一条规则。P4Runtime 按 ID 对应字段，排查时检查 ID 与值是否配对，以及字段是否重复或遗漏。

## D.6 如何整理可复现的问题

提交问题前，尽量保留一个最小程序和一组可重复的输入。说明预期结果、实际结果、工具版本、编译与启动命令，以及实际下发的表项。涉及报文路径时附端口映射、相关日志和 PCAP。

本教程的问题可提交到[本仓库 Issues](https://github.com/zhh2001/p4-language-guide-zh/issues)。一般使用问题可先搜索 [P4 Forum](https://forum.p4.org/)，工具缺陷按对应项目的贡献指引报告。更多入口见[附录 C](C-学习资源.md#c10-如何提问与报告问题)。

## D.7 本地复核记录

本附录的编译检查包括命名实参的正反例、`verify` 的调用位置、校验和片段、头文件展开与中间结果导出。运行检查覆盖 BMv2 文件日志、端口 0、可配置丢弃值、CLI 完整名称与唯一后缀，以及 Scapy 修改报文后的长度和校验和重算。

Mininet 实验发送 5 帧带有 `appendix-d-probe` 负载的报文，分别在交换机入口与出口抓包，按 PCAP 字节核对转发结果。报头有效性、哈希和 P4Runtime 的相关实验见对应章节。
