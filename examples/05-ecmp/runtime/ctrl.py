#!/usr/bin/env python3
"""
使用 P4Runtime 下发 ECMP 表项。
依赖: pip install grpcio protobuf p4runtime

前置: 启动 simple_switch_grpc (而不是 simple_switch)
    sudo simple_switch_grpc --log-console \
        -i 1@veth-s1a -i 2@veth-s1b -i 3@veth-s1c \
        --no-p4 \
        -- --grpc-server-addr 127.0.0.1:50051

之后再跑:  python3 ctrl.py
"""

import sys
import grpc
from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format


GRPC_ADDR    = "127.0.0.1:50051"
DEVICE_ID    = 0
ELECTION_ID  = p4runtime_pb2.Uint128(high=0, low=1)
P4INFO_PATH  = "../ecmp.p4info.txt"
BMV2_PATH    = "../ecmp.json"


def _id(items, name):
    for it in items:
        if it.preamble.name == name:
            return it.preamble.id
    raise KeyError(name)


def main():
    channel = grpc.insecure_channel(GRPC_ADDR)
    stub    = p4runtime_pb2_grpc.P4RuntimeStub(channel)

    # --- arbitration: 选主 ---
    def arb():
        req = p4runtime_pb2.StreamMessageRequest()
        req.arbitration.device_id = DEVICE_ID
        req.arbitration.election_id.CopyFrom(ELECTION_ID)
        yield req
        # 保持 stream 开着直到进程退出 -- 无限 yield
        while True:
            import time; time.sleep(3600); yield req

    stream = stub.StreamChannel(arb())
    print("[*] arbitration:", next(stream))

    # --- 读 P4Info + JSON ---
    p4info = p4info_pb2.P4Info()
    with open(P4INFO_PATH) as f:
        text_format.Merge(f.read(), p4info)

    with open(BMV2_PATH, "rb") as f:
        bmv2 = f.read()

    cfg = p4runtime_pb2.ForwardingPipelineConfig()
    cfg.p4info.CopyFrom(p4info)
    cfg.p4_device_config = bmv2

    req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
    req.device_id = DEVICE_ID
    req.election_id.CopyFrom(ELECTION_ID)
    req.action    = req.VERIFY_AND_COMMIT
    req.config.CopyFrom(cfg)
    stub.SetForwardingPipelineConfig(req)
    print("[*] pipeline installed")

    # --- 下发表项 ---
    def write_updates(updates):
        req = p4runtime_pb2.WriteRequest()
        req.device_id = DEVICE_ID
        req.election_id.CopyFrom(ELECTION_ID)
        req.updates.extend(updates)
        stub.Write(req)

    updates = []

    # ipv4_lpm: 10.0.2.0/24 -> set_ecmp_group(1, 2)
    te = p4runtime_pb2.TableEntry()
    te.table_id = _id(p4info.tables, "MyIngress.ipv4_lpm")
    m = te.match.add(); m.field_id = 1
    m.lpm.value      = bytes([10, 0, 2, 0])
    m.lpm.prefix_len = 24
    te.action.action.action_id = _id(p4info.actions, "MyIngress.set_ecmp_group")
    p = te.action.action.params.add(); p.param_id = 1; p.value = bytes([0, 1])   # group 1
    p = te.action.action.params.add(); p.param_id = 2; p.value = bytes([0, 2])   # size 2
    u = p4runtime_pb2.Update(); u.type = u.INSERT; u.entity.table_entry.CopyFrom(te)
    updates.append(u)

    # ecmp_group_to_nh: (1, 0) -> set_nh(...port 2)
    for hash_idx, (dmac, smac, port) in enumerate([
        (bytes.fromhex("000000000002"), bytes.fromhex("000000010001"), 2),
        (bytes.fromhex("000000000003"), bytes.fromhex("000000010002"), 3),
    ]):
        te = p4runtime_pb2.TableEntry()
        te.table_id = _id(p4info.tables, "MyIngress.ecmp_group_to_nh")
        m = te.match.add(); m.field_id = 1; m.exact.value = bytes([0, 1])
        m = te.match.add(); m.field_id = 2; m.exact.value = bytes([0, hash_idx])
        te.action.action.action_id = _id(p4info.actions, "MyIngress.set_nh")
        p = te.action.action.params.add(); p.param_id = 1; p.value = dmac
        p = te.action.action.params.add(); p.param_id = 2; p.value = smac
        p = te.action.action.params.add(); p.param_id = 3; p.value = bytes([0, port])
        u = p4runtime_pb2.Update(); u.type = u.INSERT; u.entity.table_entry.CopyFrom(te)
        updates.append(u)

    write_updates(updates)
    print("[*] tables populated. Sleeping... (Ctrl+C to exit)")

    try:
        import time
        while True: time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
