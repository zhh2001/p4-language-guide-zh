# 15 · P4Runtime 控制平面

本章说明 P4Info、流水线配置、表项更新与 StreamChannel，并用 Python 完成两组实验：配置 L2 单播表，以及通过 PacketIn/PacketOut 中转报文、读取计数器。

协议语义以 [P4Runtime 规范 v1.4.1](https://p4lang.github.io/p4runtime/spec/v1.4.1/P4Runtime-Spec.html)为准，目标实现的差异在相应小节说明。需要先运行仓库已有的控制客户端，可直接查看 [15.5.3 节的 ECMP 实验](#1553-运行仓库中的-ecmp-控制客户端)。

实测使用 p4c `1.2.5.10`、BMv2 `1.15.0-2bdd0b7b`，服务端 `Capabilities` 报告 P4Runtime API `1.3.0`。

## 15.1 P4Runtime 管理什么

P4Runtime 是控制数据平面对象的标准接口。P4Info 描述程序向控制平面暴露的表、动作及相关资源，客户端据此构造 protobuf 消息，通过 gRPC 与设备通信。

程序自定义的匹配字段和动作参数通过 P4Info 暴露给客户端。Extern 的控制接口则需要架构映射、编译器与服务端共同支持，本章使用表项和计数器对应的标准消息。

端口启停、链路配置和设备运维通常由其他管理接口负责，多控制器之间的业务状态同步由控制系统实现。

## 15.2 核心概念

### 15.2.1 P4Info

使用 `--p4runtime-files 文件.p4info.txtpb` 可生成文本 protobuf 格式的 P4Info。本章 L2 程序需要读取的对象如下：

| 对象         | 名称                | 需要读取的描述            |
| ------------ | ------------------- | ------------------------- |
| 表           | `MyIngress.dmac`    | 表 ID、匹配字段及动作引用 |
| 表内匹配字段 | `hdr.ethernet.dst`  | 字段 ID、48 位、`EXACT`   |
| 动作         | `MyIngress.forward` | 动作 ID                   |
| 动作参数     | `port`              | 参数 ID、9 位             |

表和动作使用顶层对象 ID。匹配字段 ID 在所属表内解释，动作参数 ID 在所属动作内解释，因此查找字段和参数时应先确定其所属对象。

客户端从编译产物或设备返回的配置取得与当前流水线一致的 P4Info，再按名称查找 ID。`@id` 可指定对象标识，`@name` 可指定名称，规则见[第 13 章](./13-注解与高级特性.md)。P4Info 记录的是控制平面可见的对象，被优化掉的声明或尚无目标映射的 extern 可能不会出现在其中。

### 15.2.2 ForwardingPipelineConfig

`ForwardingPipelineConfig` 包含 P4Info、目标专用的 `p4_device_config`，以及可选 cookie。本机 BMv2 接受编译生成的 JSON 字节，其他目标可能要求不同的配置格式。

`SetForwardingPipelineConfig` 的动作决定配置如何生效：

| 动作                   | 语义要点                                                                   |
| ---------------------- | -------------------------------------------------------------------------- |
| `VERIFY`               | 验证配置，不改变转发状态                                                   |
| `VERIFY_AND_SAVE`      | 保存新配置，数据平面暂不切换，后续读写按新配置解释，配合后续 `COMMIT` 使用 |
| `VERIFY_AND_COMMIT`    | 验证并安装配置，清除原转发状态                                             |
| `COMMIT`               | 提交先前保存的配置，重放保存后收到的写入，请求中不携带 `config`            |
| `RECONCILE_AND_COMMIT` | 保留转发状态并切换配置，支持情况及切换时的丢包由目标实现决定               |

本章使用 `VERIFY_AND_COMMIT`，每次安装都会重置表项等转发状态。恢复连接时，可先获取并核对已有配置，再继续读写。

### 15.2.3 TableEntry 与字节编码

普通表项通过 `table_id`、匹配字段和必要的优先级标识自身，直接动作还携带 `action_id` 与各参数的 `param_id`。插入、修改和删除分别使用 `INSERT`、`MODIFY`、`DELETE`，修改或删除时按匹配条件定位表项。

匹配字段的格式也有约束：

| 匹配种类            | 关键要求                                                 |
| ------------------- | -------------------------------------------------------- |
| `exact`             | 提供匹配值                                               |
| `lpm`               | 提供值与前缀长度，前缀以外的位须为 0，全通配时省略该字段 |
| `ternary`           | 值在掩码为 0 的位置也须为 0，全通配时省略该字段          |
| `range`、`optional` | 按各自消息格式表示范围或精确值，通配按规范省略字段       |

表含 `ternary`、`range` 或 `optional` 键时，普通表项需要正整数 `priority`，数值较大者优先。仅有 `exact`/`lpm` 键时为 0。默认表项设 `is_default_action = true`，匹配列表为空、优先级为 0，可修改的默认动作通过 `MODIFY` 更新。两种接口的优先级方向见 [8.8.1 节](./08-匹配动作表.md#881-控制平面接口的数值方向)。

对本章的 `bit<W>`，先检查数值在声明位宽内，再按大端序编码。规范的 canonical bytestring 采用能表示该数值的最短非空字节串，9 位端口值 1 编码为 `b"\x01"`，0 编码为 `b"\x00"`，接收方也应接受数值等价的前导零扩展。规范要求以 `OUT_OF_RANGE` 拒绝空串和超出位宽的数值。本机 PI 会将动作参数中的空字节串解码为 0，超位宽参数则返回 `INVALID_ARGUMENT`，客户端仍按规范编码。

### 15.2.4 StreamChannel

`StreamChannel` 是双向流，一个请求或响应通过 `oneof` 区分消息类型：

| 消息                        | 作用                                         |
| --------------------------- | -------------------------------------------- |
| `arbitration`               | 声明控制器身份，并接收主控状态变化           |
| `packet`                    | 请求方向是 PacketOut，响应方向是 PacketIn    |
| `digest`/`digest_ack`       | 服务端发送结构化摘要列表，客户端确认相应列表 |
| `idle_timeout_notification` | 通知具有相应配置的表项发生空闲超时           |
| `error`                     | 报告某些流式请求错误                         |

Digest 携带 P4 程序选择的结构化数据，PacketIn 携带报文及其控制器元数据。Clone 负责数据平面复制，副本可经配置的 CPU 路径送到控制器。

主控身份与开放的 StreamChannel 连接关联。请求生成器结束后会关闭请求方向，本机随后结束流并撤销该连接的主控身份。15.5.2 节用发送队列保持请求流，用接收线程处理服务端消息，退出会话时再关闭连接。

## 15.3 RPC 与批量操作

| RPC                           | 作用与返回方式                                        |
| ----------------------------- | ----------------------------------------------------- |
| `Write`                       | 更新表项、计数器值、多播组等实体，一元 RPC            |
| `Read`                        | 按请求读取实体，服务端流式返回，须遍历所有响应        |
| `SetForwardingPipelineConfig` | 按指定动作验证、保存或安装配置                        |
| `GetForwardingPipelineConfig` | 按请求的响应类型获取 P4Info、设备配置及 cookie 等内容 |
| `StreamChannel`               | 双向流式消息                                          |
| `Capabilities`                | 查询服务端声明的 P4Runtime API 版本                   |

`WriteRequest` 默认使用 `CONTINUE_ON_ERROR`，一项失败后仍会处理其他更新。`ROLLBACK_ON_ERROR` 和 `DATAPLANE_ATOMIC` 需要目标支持，本机对这两种模式返回 `UNIMPLEMENTED`。有依赖的操作应分成有明确先后关系的请求，并检查前一步结果。

具体实体和操作的支持情况需另行核对。本机 PI 对 `RegisterEntry`、`ValueSetEntry` 的读取返回 `UNIMPLEMENTED`，第 13 章的值集合实验使用 Thrift 接口。

## 15.4 Python 客户端环境

本章使用 gRPC 生成的 Python 绑定 `p4.v1`、`p4.config.v1`，以及 `grpcio` 和 protobuf 运行库。交互式操作可安装 `p4runtime-shell` 包，使用 [14.5.3 节的 P4Runtime Shell](./14-BMv2编译与运行.md#1453-p4runtime-shell)。

在已经安装这些依赖的 Python 环境中检查导入：

```bash
python3 -c 'import grpc; from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc; from p4.config.v1 import p4info_pb2'
```

本机旧版生成模块与 protobuf 运行库有兼容问题，需在本章 Python 命令前加 `PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python`。依赖与解释器的检查方法见 [1.3.3 节](./01-环境搭建.md#133-python-解释器与依赖)。这个兼容设置须在导入模块前生效。控制客户端连接本地 gRPC 服务通常不需要 sudo，创建网络、启动交换机和抓取原始报文则需要相应权限。

## 15.5 动手：配置 L2 单播表

### 15.5.1 编译与启动

命令从仓库根目录执行，仍使用第 14 章的 [L2 程序](../examples/02-l2-switch/l2_switch.p4)：

```bash
mkdir -p build/ch15
p4c-bm2-ss --std p4-16 --arch v1model \
    -o build/ch15/l2_switch.json \
    --p4runtime-files build/ch15/l2_switch.p4info.txtpb \
    examples/02-l2-switch/l2_switch.p4
```

按 [14.4.1 节](./14-BMv2编译与运行.md#1441-手工创建-namespace-与-veth)创建两台主机、接口与静态邻居项。保留该节的 MAC、IP 和端口映射，停止先前使用这些接口的交换机，再启动：

```bash
sudo simple_switch_grpc --device-id 15 --thrift-port 9090 \
    --log-console --log-level debug \
    -i 1@p14s1 -i 2@p14s2 --no-p4 \
    -- --grpc-server-addr 127.0.0.1:50051 --cpu-port 510
```

设备 ID 15、gRPC 地址和后续客户端保持一致。端口 510 供 15.6 节的 Packet I/O 使用，不绑定 Linux 接口。本次实验只使用默认 role，并由一个控制器配置设备。

交换机在前台运行，保留这个终端。后续控制脚本在另一终端从仓库根目录运行，Python 解释器和兼容设置仍按 [15.4 节](#154-python-客户端环境)准备。

### 15.5.2 完整控制脚本

将下面内容保存为 `build/ch15/control.py`。脚本保持仲裁流开放，检查主控响应，通过 P4Info 查找表、动作、字段和参数 ID，写入后遍历 `Read` 的全部响应。

```python
from contextlib import contextmanager
from pathlib import Path
import queue
import threading

import grpc
from google.protobuf import text_format
from p4.config.v1 import p4info_pb2
from p4.v1 import p4runtime_pb2 as pb
from p4.v1 import p4runtime_pb2_grpc as rpc

ADDRESS = "127.0.0.1:50051"
DEVICE_ID = 15


def named(items, name):
    return next(item for item in items if item.preamble.name == name)


def field(items, name):
    return next(item for item in items if item.name == name)


def uint_bytes(value, bitwidth):
    if not 0 <= value < (1 << bitwidth):
        raise ValueError("数值超出 P4Info 声明的位宽")
    return value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")


def receive(incoming, timeout=5):
    try:
        message = incoming.get(timeout=timeout)
    except queue.Empty:
        raise TimeoutError("等待 StreamChannel 消息超时") from None
    if isinstance(message, Exception):
        raise message
    if message is None:
        raise ConnectionError("StreamChannel 已结束")
    return message


@contextmanager
def session(election=(0, 1)):
    channel = grpc.insecure_channel(ADDRESS)
    outgoing, incoming = queue.Queue(), queue.Queue()
    stream = worker = None
    try:
        grpc.channel_ready_future(channel).result(timeout=5)
        stub = rpc.P4RuntimeStub(channel)
        stream = stub.StreamChannel(iter(outgoing.get, None))

        def read_stream():
            try:
                for message in stream:
                    incoming.put(message)
            except grpc.RpcError as error:
                incoming.put(error)
            finally:
                incoming.put(None)

        worker = threading.Thread(target=read_stream, daemon=True)
        worker.start()
        request = pb.StreamMessageRequest()
        request.arbitration.device_id = DEVICE_ID
        request.arbitration.election_id.high = election[0]
        request.arbitration.election_id.low = election[1]
        outgoing.put(request)
        yield stub, outgoing, incoming
    finally:
        outgoing.put(None)
        if stream is not None:
            stream.cancel()
        channel.close()
        if worker is not None:
            worker.join(timeout=2)


def require_primary(message, election=(0, 1)):
    if not message.HasField("arbitration"):
        raise RuntimeError("尚未收到仲裁响应")
    update = message.arbitration
    if (update.device_id != DEVICE_ID or not update.HasField("status")
            or update.status.code != 0
            or (update.election_id.high, update.election_id.low) != election):
        raise RuntimeError("未获得本设备的主控身份：" + str(update))


def install(stub, prefix, election=(0, 1)):
    info = p4info_pb2.P4Info()
    text_format.Parse(Path(str(prefix) + ".p4info.txtpb").read_text(), info)
    request = pb.SetForwardingPipelineConfigRequest(device_id=DEVICE_ID)
    request.election_id.high, request.election_id.low = election
    request.action = request.VERIFY_AND_COMMIT
    request.config.p4info.CopyFrom(info)
    request.config.p4_device_config = Path(str(prefix) + ".json").read_bytes()
    stub.SetForwardingPipelineConfig(request, timeout=5)
    return info


def write(stub, updates, election=(0, 1)):
    request = pb.WriteRequest(device_id=DEVICE_ID)
    request.election_id.high, request.election_id.low = election
    request.updates.extend(updates)
    stub.Write(request, timeout=5)


def main():
    with session() as (stub, outgoing, incoming):
        require_primary(receive(incoming))
        version = stub.Capabilities(pb.CapabilitiesRequest(), timeout=5)
        print("服务端 API 版本：", version.p4runtime_api_version)
        info = install(stub, "build/ch15/l2_switch")
        table = named(info.tables, "MyIngress.dmac")
        action = named(info.actions, "MyIngress.forward")
        key = field(table.match_fields, "hdr.ethernet.dst")
        port_param = field(action.params, "port")
        updates = []
        for port in (1, 2):
            update = pb.Update(type=pb.Update.INSERT)
            entry = update.entity.table_entry
            entry.table_id = table.preamble.id
            match = entry.match.add(field_id=key.id)
            match.exact.value = uint_bytes(0x020000000000 + port, key.bitwidth)
            entry.action.action.action_id = action.preamble.id
            param = entry.action.action.params.add(param_id=port_param.id)
            param.value = uint_bytes(port, port_param.bitwidth)
            updates.append(update)
        write(stub, updates)
        request = pb.ReadRequest(device_id=DEVICE_ID)
        request.entities.add().table_entry.table_id = table.preamble.id
        entries = []
        for response in stub.Read(request, timeout=5):
            entries.extend(entity.table_entry for entity in response.entities)
        if len(entries) != 2:
            raise RuntimeError("读回表项数量与本次配置不一致")
        for entry in entries:
            print(entry)
        print("PASS：两条单播表项已写入并读回")


if __name__ == "__main__":
    main()
```

运行时使用安装了相应依赖的解释器：

```bash
python3 build/ch15/control.py
```

成功后打印两条读回的表项并退出，交换机继续保留这些表项。再按第 14 章的方法从两台主机双向 ping，检查两个方向的转发结果。

该程序在新启动的实验实例上完成一次配置。长期运行的客户端应持续处理仲裁状态变化，失去主控后停止写入，主备处理见 15.8 节。

### 15.5.3 运行仓库中的 ECMP 控制客户端

仓库的 [ECMP 示例](../examples/05-ecmp/README.md#p4runtime-配置方式)提供了完整运行入口。从仓库根目录执行：

```bash
sudo bash examples/05-ecmp/run.sh --p4runtime
```

这要求 `sudo` 环境中的 `python3` 能导入 15.4 节的模块。若依赖装在虚拟环境中，可用 `P4_ECMP_PYTHON` 指定控制客户端的解释器。下面按第 1 章的安装目录举例，并加入本机旧版生成模块所需的兼容设置，实际路径应以自己的安装位置为准：

```bash
sudo env P4_ECMP_PYTHON="$HOME/p4-work/p4dev-python-venv/bin/python" \
    PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python \
    bash examples/05-ecmp/run.sh --p4runtime
```

`P4_ECMP_PYTHON` 只控制 [runtime/ctrl.py](../examples/05-ecmp/runtime/ctrl.py) 使用哪个解释器，报文验证仍由 `sudo` 环境中的 `python3` 执行，需要 Linux Python 3.12+。该模式使用 `simple_switch_grpc`，不依赖 `simple_switch_CLI` 或 P4Runtime Shell。其余命令依赖见[示例总览](../examples/README.md#运行前)。

运行脚本重新编译 ECMP，创建一个发送端与两个下一跳接收端，启动自己的交换机实例，再把设备 ID、地址和本次编译产物传给客户端。客户端确认主控身份，安装流水线，先写两个组内成员，再写引用它们的路由。读回三条表项并按字段 ID 和数值核对后退出，运行脚本接着执行与 Thrift 模式相同的逐帧验证。

ECMP 脚本独立创建程序、拓扑和配置，并将本次实例的设备 ID 传给客户端。默认使用 Thrift 9090 和 gRPC 50051，运行前应结束占用这些端口的前一实验，或按示例 README 更换端口。

ECMP 根据下一跳接收端收到的帧检查选路结果。默认完成后清理本次资源，加 `--keep` 可继续观察。单独调用 `ctrl.py` 时，需先准备好网络和交换机，报文验证由运行脚本另行执行。

## 15.6 PacketIn/PacketOut 与计数器实验

### 15.6.1 CPU 端口和报文路径

在本机 `simple_switch_grpc` 中，`--cpu-port 510` 约定：发往端口 510 的报文交给 P4Runtime 服务端，PacketOut 则从该端口注入流水线。CPU 端口由启动参数选择，须与 P4 程序一致，并避开目标的丢弃端口。

本节把端口 1、2 收到的报文送到控制器，再由控制器从另一端口发出，用于观察完整的 PacketIn/PacketOut 收发过程。

### 15.6.2 完整 P4 程序

保存为 `build/ch15/cpu.p4`。CPU 报头用 16 位端口字段保持字节对齐，数据平面的端口仍是 9 位，在转换前检查本实验允许的端口 1、2。

```p4
#include <core.p4>
#include <v1model.p4>

const bit<9> CPU_PORT = 510;

@controller_header("packet_in")
header cpu_in_t { bit<16> ingress_port; }
@controller_header("packet_out")
header cpu_out_t { bit<16> egress_port; }
struct headers { cpu_in_t cpu_in; cpu_out_t cpu_out; }
struct metadata { }

parser MyParser(packet_in packet, out headers hdr,
                inout metadata meta, inout standard_metadata_t sm) {
    state start {
        transition select(sm.ingress_port) {
            CPU_PORT: from_cpu;
            default: accept;
        }
    }
    state from_cpu {
        packet.extract(hdr.cpu_out);
        transition accept;
    }
}
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}
control MyIngress(inout headers hdr, inout metadata meta,
                  inout standard_metadata_t sm) {
    counter(512, CounterType.packets) received;
    apply {
        if (sm.parser_error != error.NoError) {
            mark_to_drop(sm);
            exit;
        }
        received.count((bit<32>)sm.ingress_port);
        if (sm.ingress_port == CPU_PORT) {
            if (hdr.cpu_out.egress_port == 1 || hdr.cpu_out.egress_port == 2) {
                sm.egress_spec = (bit<9>)hdr.cpu_out.egress_port;
            } else {
                mark_to_drop(sm);
            }
            hdr.cpu_out.setInvalid();
            exit;
        }
        sm.egress_spec = CPU_PORT;
    }
}
control MyEgress(inout headers hdr, inout metadata meta,
                 inout standard_metadata_t sm) {
    apply {
        if (sm.egress_port == CPU_PORT) {
            hdr.cpu_in.setValid();
            hdr.cpu_in.ingress_port = (bit<16>)sm.ingress_port;
        }
    }
}
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}
control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr.cpu_in); }
}
V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
```

编译：

```bash
p4test --std p4-16 build/ch15/cpu.p4
p4c-bm2-ss --std p4-16 --arch v1model \
    -o build/ch15/cpu.json \
    --p4runtime-files build/ch15/cpu.p4info.txtpb \
    build/ch15/cpu.p4
```

### 15.6.3 PacketOut 的解析与去头

`@controller_header` 描述控制器报文元数据，不会自动完成 P4 程序里的解析和封装。本机服务端把 PacketOut 元数据转换为前置 CPU 报头，再接上 `payload`，从 CPU 端口注入。

Parser 仅在入端口为 510 时提取 `cpu_out`。Ingress 检查 16 位出端口值，确认是 1 或 2 后再转为 9 位，并使该头无效。Deparser 只输出有效的 `cpu_in`，未解析的原始报文负载由 BMv2 保留。先检查再转换，可避免将 513 等值截断成端口 1。

PacketOut 应按 P4Info 中的字段 ID 和位宽提供元数据。它经 StreamChannel 异步发送，收包结果由目标端口的抓包确认。

### 15.6.4 PacketIn 的封装与计数

普通端口收到的报文被送到 510。Egress 设置 `cpu_in` 的有效位和入端口，Deparser 将它放在原始报文字节之前。本机服务端依据 P4Info 剥离该前缀，形成 PacketIn 的 `metadata` 与 `payload`。

`MyIngress.received` 按入端口统计通过本例 Parser 错误检查的报文。例如，主机 1 发出一帧，控制器再将它送回交换机从端口 2 输出，索引 1 和 510 各增加 1，分别记录主机输入与 CPU 输入。

### 15.6.5 Python 中转与计数器读取

保存为 `build/ch15/packetio.py`，与 `control.py` 放在同一目录。它复用前面的连接代码，按 `metadata_id` 取值，并通过 P4Info 确定计数器 ID。

```python
from control import (DEVICE_ID, pb, session, receive, require_primary,
                     install, named, field, uint_bytes)


def main():
    with session() as (stub, outgoing, incoming):
        require_primary(receive(incoming))
        info = install(stub, "build/ch15/cpu")
        cpu_in = named(info.controller_packet_metadata, "packet_in")
        cpu_out = named(info.controller_packet_metadata, "packet_out")
        in_port = field(cpu_in.metadata, "ingress_port")
        out_port = field(cpu_out.metadata, "egress_port")
        counter = named(info.counters, "MyIngress.received")
        print("READY：等待 PacketIn，Ctrl+C 结束", flush=True)
        while True:
            try:
                message = receive(incoming, timeout=1)
            except TimeoutError:
                continue
            if message.HasField("arbitration"):
                require_primary(message)
                continue
            if message.HasField("error"):
                raise RuntimeError(str(message.error))
            if not message.HasField("packet"):
                continue
            values = {item.metadata_id: item.value for item in message.packet.metadata}
            port = int.from_bytes(values[in_port.id], "big")
            if port not in (1, 2):
                continue
            request = pb.StreamMessageRequest()
            request.packet.payload = message.packet.payload
            item = request.packet.metadata.add(metadata_id=out_port.id)
            item.value = uint_bytes(3 - port, out_port.bitwidth)
            outgoing.put(request)
            print("PacketIn 入端口：", port, "负载字节数：", len(message.packet.payload), flush=True)

            query = pb.ReadRequest(device_id=DEVICE_ID)
            entry = query.entities.add().counter_entry
            entry.counter_id = counter.preamble.id
            entry.index.index = port
            for response in stub.Read(query, timeout=5):
                for entity in response.entities:
                    print("该入端口计数：", entity.counter_entry.data.packet_count, flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
```

保持 15.5.1 节的交换机运行，启动：

```bash
python3 build/ch15/packetio.py
```

该脚本安装 `cpu` 流水线，会替换 L2 程序并重置转发状态。看到 `READY` 后，保持客户端运行，在第三个终端执行 [14.4.1 节的双向 ping](./14-BMv2编译与运行.md#1441-手工创建-namespace-与-veth)，观察 PacketIn 的入端口、负载长度、计数器值及另一主机的收包结果。Ctrl+C 关闭客户端，这时数据平面仍把主机报文送往 CPU，因此不会继续完成中转。

本节使用的是手工创建的拓扑。实验结束后，还需停止交换机与抓包进程，再按 [14.4.1 节](./14-BMv2编译与运行.md#1441-手工创建-namespace-与-veth)删除本次命名空间和接口。

这里 `CounterEntry.index.index = port` 指定一个索引，省略 `index` 消息表示读取整个数组，显式设置 `index.index = 0` 则只读取索引 0。计数器在读请求期间仍可能更新，多次读取不是一致快照。清零时，用 `MODIFY` 向相应计数器单元写入 0。

## 15.7 典型模式：L2 学习

学习的目标是根据源 MAC 和入端口更新目的 MAC 转发表，使后续发往该 MAC 的报文能够选择正确的出端口。

一个基于 Digest 的流程可以这样组织：

1. 控制器依据 P4Info 中的 Digest ID，用 `DigestEntry` 启用并配置批量大小、等待时间和确认超时。
2. P4 程序在需要学习时发送包含源 MAC 与入端口的结构化摘要。控制器从 `DigestList.data` 读取数据，不从 PacketIn 的 `payload` 读取它。
3. 控制器更新目的 MAC 转发表。若程序另有用于抑制重复通知的源地址表，也要更新那张表，并处理 MAC 地址迁移。
4. 处理完相应列表后，发送包含 `digest_id` 和 `list_id` 的 `DigestListAck`，供服务端管理摘要缓存与去重状态。
5. 为未知目的地址和 ARP 安排泛洪、转发或丢弃策略，使用多播时配置复制组。

仓库 `02-l2-switch` 使用静态配置，实现学习功能时可在此基础上扩展 P4 程序和控制器。

## 15.8 多控制器与主备

规范按 `(device_id, role)` 分别仲裁。`election_id` 是 128 位无符号数，先比较 `high` 再比较 `low`，由控制系统协调分配。

以 v1.4.1 为准，服务端记录该设备、该 role 已见过的最高选举 ID。新主控的 ID 需要不低于该历史值，同一设备、同一 role 的不同活跃连接也须使用不同的选举 ID。主控断开后，较低 ID 的备份仍需更新选举 ID 才能接管。

| 结果或请求                    | 应如何解释                                           |
| ----------------------------- | ---------------------------------------------------- |
| 仲裁响应 `status.code = OK`   | 本连接获得主控身份，继续监听后续变化                 |
| 仲裁响应 `ALREADY_EXISTS`     | 已有其他主控，本连接为备份                           |
| 仲裁响应 `NOT_FOUND`          | 当前没有主控                                         |
| 非主控发 `Write` 或设置流水线 | 规范要求返回 `PERMISSION_DENIED`                     |
| 备份读取状态                  | 读请求不携带 election ID，仍须满足角色和访问权限要求 |

本机 PI 在主控断开后会将仍连接的较低 ID 客户端提升为主控，与上述历史最高值规则不同。实测中，备份仲裁响应为 `ALREADY_EXISTS`，备份写请求被拒绝时为 `PERMISSION_DENIED`，两者分别表示仲裁结果与写权限。

## 15.9 错误处理与常见陷阱

`Write` 的批量错误需要检查 gRPC trailing metadata 中的 `grpc-status-details-bin`。本机重复插入时，RPC 外层为 `UNKNOWN`，其中的 `google.rpc.Status.details` 按更新顺序携带 `p4.v1.Error`，重复项的 `canonical_code` 为 `ALREADY_EXISTS`，成功项为 `OK`。客户端据此定位失败的更新，再读回状态确认结果。

| 现象                                     | 检查重点                                                          |
| ---------------------------------------- | ----------------------------------------------------------------- |
| 无法导入 `p4.v1` 或发生 descriptor 错误  | 当前解释器、生成代码与 protobuf 运行库是否匹配                    |
| 建连后写请求被拒绝                       | 仲裁响应是否成功、请求流是否仍开放、设备 ID/role/选举 ID 是否一致 |
| `ALREADY_EXISTS` 或 `NOT_FOUND` 更新错误 | 表项是否已存在，选择正确的插入、修改或删除类型                    |
| 数值编码错误                             | 大端序、非空字节串、声明位宽、LPM 前缀外位或 ternary 掩码外位     |
| 写请求部分失败                           | 逐项解析错误并读回状态，不能假定整批回滚                          |
| PacketIn 收不到                          | CPU 端口配置、P4 路径、CPU 头有效位和 emit 顺序、主控流是否存活   |
| PacketOut 无输出                         | 元数据 ID 与值、Parser 的 CPU 分支、出端口检查和去头逻辑          |
| `UNIMPLEMENTED`                          | 服务端对相应 RPC、实体或操作模式的实际支持                        |

重复发送同一个 `INSERT` 会遇到已有表项，发生超时后也可能已有部分操作生效。控制器应先核对设备状态，再决定重试或补偿。配置安装与表项更新分别处理，表项写入失败时按具体错误恢复。

## 15.10 P4Runtime 与 Thrift 的边界

| 维度             | P4Runtime                                | BMv2 Thrift 接口                             |
| ---------------- | ---------------------------------------- | -------------------------------------------- |
| 对象描述         | 以 P4Info 和标准消息为基础               | 以 BMv2 JSON、专用 RPC 和对象名称等为基础    |
| 客户端           | gRPC 支持的语言及相应绑定                | 同样可编写多语言客户端，CLI 只是其中一种     |
| 控制器报文与摘要 | 由 StreamChannel 的不同消息承载          | 能力依赖 BMv2 专用机制，不能套用相同消息模型 |
| 适用考虑         | 跨实现接口、控制器集成，同时核对目标支持 | 本地实验及 BMv2 特定功能                     |

同一设备上并用两套接口时，应明确各自管理的对象。本机 Thrift 写入会绕过 P4Runtime 服务维护的表项状态，实验中由一种接口管理同一张表。

## 15.11 本章小结

P4Info 决定对象和数据格式，仲裁决定谁能修改状态，流水线配置决定这些对象由哪个程序实现。保持控制连接、检查逐项结果、读回状态和验证报文，是控制程序正常工作的共同条件。Packet I/O 还要求服务端与 P4 程序对 CPU 头和端口作出一致约定。

## 15.12 下一步

进一步实现控制器时，可继续查阅本章引用的协议规范和 Python 绑定。[第 16 章](./16-PSA与TNA简介.md)讨论不同架构的接口，以及迁移数据平面和控制平面时需要重新核对的部分。
