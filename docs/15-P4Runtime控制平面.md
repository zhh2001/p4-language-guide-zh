# 15 · P4Runtime 控制平面

> 本章目标：理解 **P4Runtime** 这套标准南向接口的来龙去脉，并亲手用 Python 给 BMv2 下发表项、读计数器、处理 packet-in。

## 15.1 为什么不用 OpenFlow

OpenFlow 的字段是硬编码的——加新协议必须改协议本身。P4Runtime 相反：

> **先有 P4 程序，再根据它生成 `p4info.txt`，控制平面基于这个"清单"与数据平面对话。**

好处：

1. 支持任何自定义表 / 动作 / extern
2. gRPC 传输，跨语言（Python/Go/C++/Java）
3. 支持多控制器、抢占式选举、流式 packet-in/out
4. 标准化：P4.org 维护，协议 buffer 定义公开（[p4runtime.proto](https://github.com/p4lang/p4runtime)）

## 15.2 核心概念

### 15.2.1 P4Info

编译 P4 程序时，`p4c --p4runtime-files prog.p4info.txt` 会生成一份 **P4Info** 文件（protobuf 文本）。里面记录：

- 所有表的名字、键字段、match_kind、大小
- 所有 action 的名字、参数（含 id）
- 所有 extern 实例（counter、register、digest）
- P4Runtime id（用 `@id(...)` 或自动分配）

一份典型 P4Info 片段：

```text
tables {
  preamble { id: 33576300 name: "MyIngress.ipv4_lpm" alias: "ipv4_lpm" }
  match_fields { id: 1 name: "hdr.ipv4.dstAddr" bitwidth: 32 match_type: LPM }
  action_refs { id: 16777217 }
  action_refs { id: 16777218 }
  size: 1024
}
actions {
  preamble { id: 16777217 name: "MyIngress.set_nhop" alias: "set_nhop" }
  params { id: 1 name: "nh" bitwidth: 32 }
  params { id: 2 name: "port" bitwidth: 9 }
}
```

控制平面要下发表项时，**必须**先读 P4Info，才能知道 id 和字段长度。

### 15.2.2 Pipeline Config

控制平面通过 `SetForwardingPipelineConfig` RPC 把 **P4Info + 目标二进制（BMv2 JSON）** 推给交换机。这一步等于"安装程序"。

### 15.2.3 Table Entry

每一条表项 = `TableEntry`：

```text
TableEntry {
  table_id:     33576300
  match:        [ LPM("10.0.1.0/24") ]
  action:       { action_id: 16777217, params: [nh=0x0A000101, port=0x01] }
  priority:     0          # ternary 才需要
  controller_metadata: 0
}
```

### 15.2.4 Stream Channel

一条长连接，用来：

- **packet-in**：数据平面 `digest` / `clone` 上来的消息
- **packet-out**：控制平面直接注入报文（常用于 L2 学习、ARP 响应）
- **Arbitration**：多个控制器时选主

## 15.3 P4Runtime 的 RPC 方法

| RPC | 作用 |
| --- | ---- |
| `Write` | 插入/修改/删除表项、counter reset、多播组等 |
| `Read` | 查询表项/计数器/寄存器 |
| `SetForwardingPipelineConfig` | 安装 P4 程序 |
| `GetForwardingPipelineConfig` | 拿回当前 P4Info |
| `StreamChannel` | 双向流：packet-in/out、arbitration |

## 15.4 安装 Python 客户端

两种常见：

- **`p4runtime-shell`**：交互式 REPL，适合调试（见 [14.5.3](./14-BMv2编译与运行.md#1453-p4runtime-shell)）
- **裸 gRPC + `p4runtime-python`**：写控制应用

```bash
pip install grpcio protobuf p4runtime  # 或者用 p4lang 官方的 client 库
```

P4Runtime 官方 Python 辅助：[`p4lang/p4runtime/py`](https://github.com/p4lang/p4runtime)。

## 15.5 动手：用 Python 控制 BMv2

### 15.5.1 启动 simple_switch_grpc

```bash
sudo simple_switch_grpc \
    -i 1@veth1 -i 2@veth3 \
    --no-p4 \
    -- --grpc-server-addr 127.0.0.1:50051 \
       --cpu-port 510
```

### 15.5.2 控制脚本（简化版）

```python
# control.py
import grpc
from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format

CHANNEL = grpc.insecure_channel('127.0.0.1:50051')
STUB    = p4runtime_pb2_grpc.P4RuntimeStub(CHANNEL)

DEVICE_ID   = 0
ELECTION_ID = p4runtime_pb2.Uint128(high=0, low=1)

# 1) 选主
def master_arbitration():
    request = p4runtime_pb2.StreamMessageRequest()
    request.arbitration.device_id       = DEVICE_ID
    request.arbitration.election_id.CopyFrom(ELECTION_ID)
    yield request

stream = STUB.StreamChannel(master_arbitration())
print('selected as master:', next(stream).arbitration)

# 2) 推送 pipeline
p4info = p4info_pb2.P4Info()
with open('hello.p4info.txt') as f:
    text_format.Merge(f.read(), p4info)

with open('hello.json', 'rb') as f:
    bmv2_json = f.read()

cfg = p4runtime_pb2.ForwardingPipelineConfig()
cfg.p4info.CopyFrom(p4info)
cfg.p4_device_config = bmv2_json

req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
req.device_id   = DEVICE_ID
req.election_id.CopyFrom(ELECTION_ID)
req.action      = req.VERIFY_AND_COMMIT
req.config.CopyFrom(cfg)
STUB.SetForwardingPipelineConfig(req)

# 3) 插入表项：MyIngress.ipv4_lpm match LPM(10.0.1.0/24) -> set_nhop(10.0.1.1, 1)
def get_id_by_name(items, name):
    for it in items:
        if it.preamble.name == name:
            return it.preamble.id
    raise KeyError(name)

table_id  = get_id_by_name(p4info.tables,  'MyIngress.ipv4_lpm')
action_id = get_id_by_name(p4info.actions, 'MyIngress.set_nhop')

te = p4runtime_pb2.TableEntry()
te.table_id = table_id

m = te.match.add()
m.field_id = 1  # hdr.ipv4.dstAddr
m.lpm.value   = bytes([10, 0, 1, 0])
m.lpm.prefix_len = 24

te.action.action.action_id = action_id
p = te.action.action.params.add(); p.param_id = 1; p.value = bytes([10, 0, 1, 1])
p = te.action.action.params.add(); p.param_id = 2; p.value = bytes([0, 1])

write = p4runtime_pb2.WriteRequest()
write.device_id   = DEVICE_ID
write.election_id.CopyFrom(ELECTION_ID)
u = write.updates.add()
u.type = u.INSERT
u.entity.table_entry.CopyFrom(te)
STUB.Write(write)

print('Rule inserted')
```

完整可运行代码见 [`examples/05-ecmp/runtime/ctrl.py`](../examples/05-ecmp/runtime/ctrl.py)。

## 15.6 Packet-in / Packet-out

### 15.6.1 CPU Port 约定

P4 程序约定一个 **CPU 端口**（V1Model 通常是 510 或 255）。

- 数据平面想送包给控制平面 → 设 `egress_spec = CPU_PORT`
- 控制平面想注入包 → StreamChannel 发 `PacketOut`

### 15.6.2 定义 cpu header

```p4
@controller_header("packet_in")
header packet_in_t  { bit<9> ingress_port; bit<7> _pad; }

@controller_header("packet_out")
header packet_out_t { bit<9> egress_port;  bit<7> _pad; }

struct headers {
    packet_in_t  packet_in;
    packet_out_t packet_out;
    /* ... 其他 ... */
}
```

`@controller_header` 告诉 p4c 把这层 header 元数据记入 P4Info，**不作为 ethernet 的一部分**，方便控制平面按字段名访问。

### 15.6.3 Ingress 处理 Packet-out

```p4
apply {
    if (hdr.packet_out.isValid()) {
        std_meta.egress_spec = hdr.packet_out.egress_port;
        hdr.packet_out.setInvalid();    // 剥掉 CPU 头
        return;
    }
    /* 正常逻辑 */
}
```

### 15.6.4 Egress 填充 Packet-in

```p4
apply {
    if (std_meta.egress_port == CPU_PORT) {
        hdr.packet_in.setValid();
        hdr.packet_in.ingress_port = std_meta.ingress_port;
    }
}
```

### 15.6.5 控制平面接收

```python
for msg in stream:
    if msg.HasField('packet'):
        packet_in = msg.packet
        print('packet_in from port', int.from_bytes(packet_in.metadata[0].value, 'big'))
        print('payload =', packet_in.payload.hex())
```

## 15.7 典型模式：L2 学习

流水线里维护一张 "src_mac → port" 表。未命中则：

1. Ingress 用 `digest` 把 `{src_mac, ingress_port}` 上送
2. 控制平面收到，调用 Write RPC 把对应表项插回来
3. 下一个同源 MAC 的包就能命中

示例代码见 [`examples/02-l2-switch/runtime/learn.py`](../examples/02-l2-switch/runtime/learn.py)。

## 15.8 多控制器与主备

P4Runtime 通过 **election_id** 选主。更大的 id = 主；从机会收到 `FAILED_PRECONDITION`。

- 主机：Write / SetConfig / Read 皆可
- 从机：只能 Read

用途：HA、滚动升级。

## 15.9 常见陷阱

| 问题 | 原因 | 解决 |
| ---- | ---- | ---- |
| `INVALID_ARGUMENT: match field length mismatch` | 字段字节数和 bitwidth 不匹配 | 注意字段要按 **big-endian 最小字节数** 编码 |
| `FAILED_PRECONDITION: not primary` | election_id 不是最大 | 增大 id 重试 |
| packet_in 收不到 | `@controller_header` 没设 / CPU port 没配 | 检查 Ingress 是否正确置 egress_spec |
| 下发表项 `TABLE_ENTRY_DUPLICATE_ENTRY` | 已存在，应该用 `MODIFY` | 改 `u.type = u.MODIFY` |

## 15.10 P4Runtime vs Thrift CLI 选择

| 维度 | P4Runtime | `simple_switch_CLI`（Thrift） |
| ---- | --------- | ---------------------------- |
| 标准化 | 是 | 仅 BMv2 |
| 语言 | 任意 gRPC 客户端 | 仅 CLI |
| 流式消息 | 支持 packet-in/out、digest | 支持，但不方便 |
| 适合生产 | ✅ | ❌（调试用） |
| 适合快速调试 | 一般 | ✅ |

**推荐**：

- 临时实验、跑通示例 → `simple_switch_CLI`
- 写控制应用、接入 SDN 控制器 → P4Runtime

## 15.11 本章小结

- P4Runtime = gRPC + P4Info + 流式消息
- 四步走：**读 P4Info → 选主 → 推送 pipeline → Write/Read 表项**
- packet-in/out 用 `@controller_header` 声明 CPU 头
- 生产场景首选 P4Runtime；教学调试可以 CLI

## 15.12 下一步

你已经能写出完整的"数据平面 + 控制平面"配对。下一章我们扫一眼生产级的架构 [16 · PSA 与 TNA 简介](./16-PSA与TNA简介.md)，给你日后迁移做准备。
