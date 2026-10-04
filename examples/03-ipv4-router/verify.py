#!/usr/bin/env python3
"""逐帧验证两主机拓扑中的 IPv4 转发、报头修改和输入检查。"""

import argparse
from contextlib import ExitStack
import os
import secrets
import select
import socket
import struct
import time

HOST_IPS = ("10.0.1.1", "10.0.2.2")
HOST_MACS = (bytes.fromhex("000000000101"), bytes.fromhex("000000000202"))
ROUTER_MACS = (bytes.fromhex("000000010101"), bytes.fromhex("000000020202"))


def checksum(data):
    if len(data) % 2:
        data += b"\x00"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff


def make_frame(source, length=128, ttl=64, version=4, ihl=5,
               total_len=None, destination=None, fragment=0, udp=False):
    """构造带随机标识的以太帧。length 不含 FCS，ihl=6 时带四字节选项。"""
    destination = destination or HOST_IPS[1 - source]
    marker = b"ROUTER-P4:" + secrets.token_bytes(12)
    options = b"\x01\x01\x01\x00" if ihl == 6 else b""
    payload_size = length - 14 - 20 - len(options) - (8 if udp else 0)
    if payload_size < len(marker):
        raise ValueError("帧长不足以容纳测试标识")
    payload = marker + secrets.token_bytes(payload_size - len(marker))
    src_ip, dst_ip = socket.inet_aton(HOST_IPS[source]), socket.inet_aton(destination)
    protocol = 17 if udp else 253
    if udp:
        segment = struct.pack("!HHHH", 1234, 9000, 8 + len(payload), 0) + payload
        pseudo = src_ip + dst_ip + struct.pack("!BBH", 0, protocol, len(segment))
        value = checksum(pseudo + segment) or 0xffff
        payload = segment[:6] + struct.pack("!H", value) + segment[8:]
    ip_length = total_len if total_len is not None else 20 + len(options) + len(payload)
    header = struct.pack("!BBHHHBBH4s4s", version * 16 + ihl, 0, ip_length,
                         secrets.randbits(16), fragment, ttl, protocol, 0, src_ip, dst_ip)
    header += options
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    frame = ROUTER_MACS[source] + HOST_MACS[source] + b"\x08\x00" + header + payload
    return frame, marker


def forwarded(frame, destination):
    header = bytearray(frame[14:34])
    header[8] -= 1
    header[10:12] = b"\x00\x00"
    header[10:12] = struct.pack("!H", checksum(header))
    return (HOST_MACS[destination] + ROUTER_MACS[destination] + frame[12:14]
            + bytes(header) + frame[34:])


def cases():
    """返回 (名称、入端口下标、输入帧、标识、预期出端口下标或 None)。"""
    for source in range(2):
        for length in (60, 128, 1514):
            frame, marker = make_frame(source, length=length)
            yield f"h{source + 1} 正常转发 {length} 字节", source, frame, marker, 1 - source
        for ttl in (2, 255):
            frame, marker = make_frame(source, ttl=ttl)
            yield f"h{source + 1} TTL={ttl}", source, frame, marker, 1 - source
        frame, marker = make_frame(source, udp=True)
        yield f"h{source + 1} UDP 负载保持", source, frame, marker, 1 - source
        # 非末片负载 32 字节，满足 8 字节对齐。末片的偏移为 4（32 字节）。
        for fragment in (0x2000, 4):
            frame, marker = make_frame(source, length=66, fragment=fragment)
            yield f"h{source + 1} 分片字段 {fragment:#06x}", source, frame, marker, 1 - source
        frame, marker = make_frame(source, length=60)
        yield f"h{source + 1} 帧尾填充保持", source, frame + b"\xa5" * 12, marker, 1 - source

        for label, kwargs in (
            ("TTL=0", {"ttl": 0}),
            ("TTL=1", {"ttl": 1}),
            ("错误版本", {"version": 6}),
            ("IHL 小于 5", {"ihl": 4}),
            ("IPv4 选项", {"ihl": 6}),
            ("totalLen 小于 20", {"total_len": 19}),
            ("totalLen 超过实际输入", {"total_len": 500}),
            ("路由未命中", {"destination": "10.0.3.3"}),
            ("同网段其他主机无路由", {"destination": f"10.0.{2 - source}.99"}),
        ):
            frame, marker = make_frame(source, **kwargs)
            yield f"h{source + 1} 丢弃 {label}", source, frame, marker, None
        frame, marker = make_frame(source)
        broken = bytearray(frame)
        broken[24] ^= 1
        yield f"h{source + 1} 丢弃错误校验和", source, bytes(broken), marker, None
        yield f"h{source + 1} 丢弃非 IPv4", source, frame[:12] + b"\x88\xb5" + frame[14:], marker, None
        yield f"h{source + 1} 丢弃 VLAN", source, frame[:12] + b"\x81\x00\x00\x01" + frame[12:], marker, None


def open_socket(namespace):
    with open("/proc/self/ns/net", "rb") as original:
        with open(f"/var/run/netns/{namespace}", "rb") as target:
            os.setns(target.fileno(), os.CLONE_NEWNET)
        try:
            sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
            try:
                sock.bind(("eth0", 0))
                sock.setblocking(False)
            except BaseException:
                sock.close()
                raise
        finally:
            os.setns(original.fileno(), os.CLONE_NEWNET)
    return sock


def check_frame(sockets, label, source, frame, marker, destination):
    expected = forwarded(frame, destination) if destination is not None else None
    marker_offset = frame.index(marker)
    if sockets[source].send(frame) != len(frame):
        raise RuntimeError("未能发送完整测试帧")
    count = 0
    deadline = time.monotonic() + (3 if expected is not None else 0.3)
    while time.monotonic() < deadline:
        ready, _, _ = select.select(sockets, [], [], max(0, deadline - time.monotonic()))
        for sock in ready:
            received, address = sock.recvfrom(65535)
            # ICMP 错误报文可能引用原始负载，只匹配原位置上的标识。
            if (address[2] == socket.PACKET_OUTGOING
                    or received[marker_offset:marker_offset + len(marker)] != marker):
                continue
            if destination is None or sock is not sockets[destination]:
                raise RuntimeError(f"{label}：不应输出的端口收到测试帧")
            if received != expected:
                raise RuntimeError(f"{label}：MAC、TTL、校验和或负载与预期不符")
            count += 1
            if count > 1:
                raise RuntimeError(f"{label}：收到重复副本")
            deadline = time.monotonic() + 0.3
    if count != int(expected is not None):
        raise RuntimeError(f"{label}：未收到预期输出")
    print(f"PASS：{label}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespaces", nargs=2, metavar="命名空间")
    args = parser.parse_args()
    if not hasattr(os, "setns"):
        parser.error("需要 Linux Python 3.12+（os.setns）")
    if len(set(args.namespaces)) != 2:
        parser.error("按 h1、h2 顺序提供两个不同的命名空间")
    with ExitStack() as stack:
        sockets = [stack.enter_context(open_socket(name)) for name in args.namespaces]
        if tuple(sock.getsockname()[4] for sock in sockets) != HOST_MACS:
            raise RuntimeError("主机 MAC 或命名空间顺序与静态配置不符")
        for case in cases():
            check_frame(sockets, *case)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"FAIL：{error}") from error
