#!/usr/bin/env python3
"""向专用 BMv2 P4Runtime 实例安装本例流水线和表项，读回核对后退出。

VERIFY_AND_COMMIT 会清除原有转发状态。请仅对本例新建的实验实例运行。
依赖及旧版 protobuf 模块的兼容设置见 docs/15-P4Runtime控制平面.md。
"""

import argparse
from contextlib import contextmanager
from pathlib import Path
import queue
import signal
import threading

import grpc
from google.protobuf import text_format
from p4.config.v1 import p4info_pb2
from p4.v1 import p4runtime_pb2 as pb
from p4.v1 import p4runtime_pb2_grpc as rpc


def named(items, name, preamble=False):
    for item in items:
        if (item.preamble.name if preamble else item.name) == name:
            return item
    raise ValueError(f"P4Info 缺少对象：{name}")


def uint_bytes(value, bitwidth):
    if not 0 <= value < 1 << bitwidth:
        raise ValueError(f"{value} 超出 bit<{bitwidth}> 范围")
    return value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")


def table_entry(info, table_name, action_name, matches, params):
    table = named(info.tables, table_name, preamble=True)
    action = named(info.actions, action_name, preamble=True)
    if action.preamble.id not in {ref.id for ref in table.action_refs}:
        raise ValueError(f"{table_name} 不允许动作 {action_name}")
    if set(matches) != {field.name for field in table.match_fields}:
        raise ValueError(f"{table_name} 的匹配字段与预期不符")
    if set(params) != {param.name for param in action.params}:
        raise ValueError(f"{action_name} 的参数与预期不符")
    entry = pb.TableEntry(table_id=table.preamble.id)
    for name, value in matches.items():
        field = named(table.match_fields, name)
        match = entry.match.add(field_id=field.id)
        if isinstance(value, tuple):
            if field.match_type != p4info_pb2.MatchField.LPM:
                raise ValueError(f"{name} 不是 LPM 字段")
            address, prefix = value
            if not 1 <= prefix <= field.bitwidth or address & ((1 << (field.bitwidth - prefix)) - 1):
                raise ValueError("LPM 前缀长度或主机位不合法")
            match.lpm.value = uint_bytes(address, field.bitwidth)
            match.lpm.prefix_len = prefix
        else:
            if field.match_type != p4info_pb2.MatchField.EXACT:
                raise ValueError(f"{name} 不是 EXACT 字段")
            match.exact.value = uint_bytes(value, field.bitwidth)
    entry.action.action.action_id = action.preamble.id
    for name, value in params.items():
        param = named(action.params, name)
        entry.action.action.params.add(param_id=param.id,
                                       value=uint_bytes(value, param.bitwidth))
    return entry


def entries(info):
    members = []
    for index, (dmac, smac, port) in enumerate((
        (0x000000000002, 0x000000010001, 2),
        (0x000000000003, 0x000000010002, 3),
    )):
        members.append(table_entry(
            info, "MyIngress.ecmp_group_to_nh", "MyIngress.set_nh",
            {"meta.ecmp_group_id": 1, "meta.ecmp_hash": index},
            {"dmac": dmac, "smac": smac, "port": port}))
    route = table_entry(info, "MyIngress.ipv4_lpm", "MyIngress.set_ecmp_group",
                        {"hdr.ipv4.dst": (0x0a000200, 24)},
                        {"group_id": 1, "group_size": 2})
    return members, route


def normalized(entry):
    """按 ID 和数值比较，忽略 repeated 字段顺序及合法的前导零差异。"""
    keys = []
    for match in entry.match:
        kind = match.WhichOneof("field_match_type")
        if kind == "exact":
            keys.append((match.field_id, kind, int.from_bytes(match.exact.value, "big"), 0))
        elif kind == "lpm":
            keys.append((match.field_id, kind, int.from_bytes(match.lpm.value, "big"), match.lpm.prefix_len))
        else:
            raise ValueError(f"读回了非预期的匹配类型：{kind}")
    action = entry.action.action
    params = sorted((param.param_id, int.from_bytes(param.value, "big")) for param in action.params)
    return (entry.table_id, entry.is_default_action, entry.priority,
            tuple(sorted(keys)), action.action_id, tuple(params))


@contextmanager
def session(address, device_id, election):
    channel = grpc.insecure_channel(address)
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
        request.arbitration.device_id = device_id
        request.arbitration.election_id.low = election
        outgoing.put(request)
        try:
            message = incoming.get(timeout=5)
        except queue.Empty:
            raise TimeoutError("等待仲裁响应超时") from None
        if isinstance(message, Exception):
            raise message
        if message is None or not message.HasField("arbitration"):
            raise RuntimeError("未收到仲裁响应")
        update = message.arbitration
        if (update.device_id != device_id or update.election_id.high != 0
                or update.election_id.low != election or not update.HasField("status")
                or update.status.code != 0):
            raise RuntimeError("未获得本设备的主控身份：" + str(update))
        yield stub
    finally:
        outgoing.put(None)
        if stream is not None:
            stream.cancel()
        channel.close()
        if worker is not None:
            worker.join(timeout=2)


def write(stub, device_id, election, table_entries):
    request = pb.WriteRequest(device_id=device_id)
    request.election_id.low = election
    for entry in table_entries:
        request.updates.add(type=pb.Update.INSERT).entity.table_entry.CopyFrom(entry)
    stub.Write(request, timeout=5)


def main():
    example = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", default="127.0.0.1:50051")
    parser.add_argument("--device-id", type=int, default=0)
    parser.add_argument("--election-id", type=int, default=1, help="默认 role 的 election_id.low")
    parser.add_argument("--p4info", type=Path, default=example / "ecmp.p4info.txtpb")
    parser.add_argument("--json", type=Path, default=example / "ecmp.json")
    args = parser.parse_args()
    if not 0 <= args.device_id < 1 << 64 or not 1 <= args.election_id < 1 << 64:
        parser.error("device-id 需在 uint64 范围内，election-id 需为非零 uint64")
    info = p4info_pb2.P4Info()
    text_format.Parse(args.p4info.read_text(), info)
    config = args.json.read_bytes()
    members, route = entries(info)
    with session(args.address, args.device_id, args.election_id) as stub:
        request = pb.SetForwardingPipelineConfigRequest(device_id=args.device_id)
        request.election_id.low = args.election_id
        request.action = request.VERIFY_AND_COMMIT
        request.config.p4info.CopyFrom(info)
        request.config.p4_device_config = config
        stub.SetForwardingPipelineConfig(request, timeout=5)
        # 两个成员先写成功，再用独立请求安装引用它们的路由。
        write(stub, args.device_id, args.election_id, members)
        write(stub, args.device_id, args.election_id, [route])
        read = pb.ReadRequest(device_id=args.device_id)
        for table_id in sorted({route.table_id, members[0].table_id}):
            read.entities.add().table_entry.table_id = table_id
        actual = [normalized(entity.table_entry)
                  for reply in stub.Read(read, timeout=5) for entity in reply.entities]
        expected = [normalized(entry) for entry in [*members, route]]
        if sorted(actual) != sorted(expected):
            raise RuntimeError("读回的 ECMP 表项与预期不符")
    print("PASS：P4Runtime 主控确认、流水线安装及 3 条表项读回完成", flush=True)


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except grpc.RpcError as error:
        raise SystemExit(f"FAIL：P4Runtime {error.code().name}: {error.details()}") from error
    except grpc.FutureTimeoutError as error:
        raise SystemExit("FAIL：等待 gRPC 服务超时") from error
    except (OSError, RuntimeError, ValueError, TimeoutError, text_format.ParseError) as error:
        raise SystemExit(f"FAIL：{error}") from error
