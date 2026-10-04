#!/usr/bin/env python3
"""在 h1、nh1、nh2 命名空间中验证 ECMP 选路、报头改写和丢弃行为。"""

import argparse
from collections import Counter
from contextlib import ExitStack
from dataclasses import dataclass
import os
import secrets
import select
import socket
import struct
import time
import zlib

HOST_MAC = bytes.fromhex("000000000001")
NEXT_MACS = (bytes.fromhex("000000000002"), bytes.fromhex("000000000003"))
ROUTER_MACS = (bytes.fromhex("000000010001"), bytes.fromhex("000000010002"))
GATEWAY_MAC = bytes.fromhex("000000010000")
MARKER_PREFIX = b"ECMP:"
MARKER_SIZE = len(MARKER_PREFIX) + 12


def checksum(data):
    data += b"\x00" if len(data) % 2 else b""
    value = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while value >> 16:
        value = (value & 0xffff) + (value >> 16)
    return (~value) & 0xffff


def make_frame(src="10.0.1.1", dst="10.0.2.10", protocol=6, sport=1234,
               dport=80, length=128, ttl=64, version=4, ihl=5, total_len=None,
               fragment=0, tcp_offset=5, udp_length=None):
    marker = MARKER_PREFIX + secrets.token_bytes(12)
    options = b"\x01\x01\x01\x00" if ihl == 6 else b""
    tcp_options = b"\x01\x01\x01\x00" if tcp_offset == 6 else b""
    transport_size = 20 + len(tcp_options) if protocol == 6 else 8 if protocol in (1, 17) else 0
    payload_size = length - 34 - len(options) - transport_size
    if payload_size < len(marker):
        raise ValueError("帧太短，无法容纳测试标识")
    payload = marker.ljust(payload_size, b"\x5a")
    src_ip, dst_ip = socket.inet_aton(src), socket.inet_aton(dst)
    if protocol == 6:
        segment = struct.pack("!HHIIBBHHH", sport, dport, secrets.randbits(32), 0,
                              tcp_offset << 4, 2, 4096, 0, 0) + tcp_options + payload
        check_offset = 16
    elif protocol == 17:
        size = 8 + len(payload) if udp_length is None else udp_length
        segment = struct.pack("!HHHH", sport, dport, size, 0) + payload
        check_offset = 6
    elif protocol == 1:
        segment = struct.pack("!BBHHH", 8, 0, 0, 1, 1) + payload
        segment = segment[:2] + struct.pack("!H", checksum(segment)) + segment[4:]
    else:
        segment = payload
    if protocol in (6, 17):
        pseudo = src_ip + dst_ip + struct.pack("!BBH", 0, protocol, len(segment))
        value = checksum(pseudo + segment)
        if protocol == 17 and value == 0:
            value = 0xffff
        segment = segment[:check_offset] + struct.pack("!H", value) + segment[check_offset + 2:]
    ip_length = 20 + len(options) + len(segment) if total_len is None else total_len
    header = struct.pack("!BBHHHBBH4s4s", version << 4 | ihl, 0, ip_length,
                         secrets.randbits(16), fragment, ttl, protocol, 0, src_ip, dst_ip) + options
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return GATEWAY_MAC + HOST_MAC + b"\x08\x00" + header + segment, marker


def bucket(frame, size=2):
    # 本机 BMv2 按 P4 元组顺序拼接 32+32+8+16+16 位，均按网络字节序。
    ports = frame[34:38] if frame[23] in (6, 17) else b"\x00" * 4
    return zlib.crc32(frame[26:34] + frame[23:24] + ports) % size


def forwarded(frame, index):
    header = bytearray(frame[14:34])
    header[8] -= 1
    header[10:12] = b"\x00\x00"
    header[10:12] = struct.pack("!H", checksum(header))
    return NEXT_MACS[index] + ROUTER_MACS[index] + frame[12:14] + header + frame[34:]


@dataclass
class Case:
    label: str
    frame: bytes
    marker: bytes
    output: int | None  # 套接字顺序为 h1、nh1、nh2，输出索引为 1 或 2。


def case(label, drop=False, **kwargs):
    frame, marker = make_frame(**kwargs)
    return Case(label, frame, marker, None if drop else bucket(frame) + 1)


def boundary_cases():
    result = []
    for length in (60, 128, 1514):
        result.append(case(f"UDP {length} 字节", protocol=17, length=length))
    for ttl in (2, 255):
        result.append(case(f"TTL={ttl}", ttl=ttl))
    for kwargs in ({"src": "10.0.1.2"}, {"dst": "10.0.2.11"}, {"dport": 443},
                   {"protocol": 17}, {"protocol": 1}, {"protocol": 253}):
        result.append(case(f"哈希键 {kwargs}", **kwargs))
    result.append(case("TCP 选项保持", tcp_offset=6))
    padded = case("帧尾字节保持", protocol=17)
    padded.frame += b"\xa5" * 12
    result.append(padded)
    bad_tcp = case("不验证 TCP 校验和")
    frame = bytearray(bad_tcp.frame)
    frame[50] ^= 1
    bad_tcp.frame = bytes(frame)
    result.append(bad_tcp)
    for label, kwargs in (
        ("TTL=0", {"ttl": 0}), ("TTL=1", {"ttl": 1}),
        ("路由未命中", {"dst": "10.0.3.10"}),
        ("错误版本", {"version": 6}), ("IHL 小于 5", {"ihl": 4}),
        ("IPv4 选项", {"ihl": 6}), ("IP 总长度小于 20", {"total_len": 19}),
        ("IP 总长度超过帧", {"total_len": 500}),
        ("TCP 长度不足", {"total_len": 39}),
        ("TCP dataOffset 小于 5", {"tcp_offset": 4}),
        ("TCP dataOffset 超出负载", {"tcp_offset": 15, "total_len": 40}),
        ("UDP 长度不足", {"protocol": 17, "total_len": 27}),
        ("UDP length 小于 8", {"protocol": 17, "udp_length": 7}),
        ("UDP length 超出负载", {"protocol": 17, "udp_length": 500}),
        ("首片", {"fragment": 0x2000}), ("后续片", {"fragment": 1}),
    ):
        result.append(case(label, drop=True, **kwargs))
    bad_ip = case("错误 IPv4 校验和", drop=True)
    frame = bytearray(bad_ip.frame)
    frame[24] ^= 1
    bad_ip.frame = bytes(frame)
    result.append(bad_ip)
    other = case("非 IPv4", drop=True)
    other.frame = other.frame[:12] + b"\x88\xb5" + other.frame[14:]
    result.append(other)
    vlan = case("VLAN", drop=True)
    vlan.frame = vlan.frame[:12] + b"\x81\x00\x00\x01" + vlan.frame[12:]
    result.append(vlan)
    return result


def open_socket(namespace):
    with open("/proc/self/ns/net", "rb") as original:
        with open(f"/var/run/netns/{namespace}", "rb") as target:
            os.setns(target.fileno(), os.CLONE_NEWNET)
        try:
            sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
                sock.bind(("eth0", 0))
                sock.setblocking(False)
            except BaseException:
                sock.close()
                raise
        finally:
            os.setns(original.fileno(), os.CLONE_NEWNET)
    return sock


def check_batch(sockets, tests, quiet=0.2):
    by_marker = {test.marker: test for test in tests}
    seen = Counter()
    expected_count = sum(test.output is not None for test in tests)
    for test in tests:
        if sockets[0].send(test.frame) != len(test.frame):
            raise RuntimeError("未能发送完整测试帧")
        # 本例验证功能，限速避免突发报文耗尽软件交换机的队列。
        time.sleep(0.001)
    deadline = time.monotonic() + (3 if expected_count else quiet)
    while time.monotonic() < deadline:
        ready, _, _ = select.select(sockets, [], [], max(0, deadline - time.monotonic()))
        for sock in ready:
            received, address = sock.recvfrom(65535)
            if address[2] == socket.PACKET_OUTGOING:
                continue
            offset = received.find(MARKER_PREFIX)
            test = by_marker.get(received[offset:offset + MARKER_SIZE]) if offset >= 0 else None
            # 排除 Linux 发出的 ICMP 错误，它们会在其他位置引用测试负载。
            if test is None or offset != test.frame.index(test.marker):
                continue
            if test.output is None or sock is not sockets[test.output]:
                raise RuntimeError(f"{test.label}：不应输出的端口收到测试帧")
            if received != forwarded(test.frame, test.output - 1):
                raise RuntimeError(f"{test.label}：MAC、TTL、校验和或负载不符")
            seen[test.marker] += 1
            if seen[test.marker] != 1:
                raise RuntimeError(f"{test.label}：收到重复副本")
            if sum(seen.values()) == expected_count:
                deadline = time.monotonic() + quiet
    missing = [test.label for test in tests if test.output is not None and not seen[test.marker]]
    if missing:
        raise RuntimeError(f"未收到预期输出：{missing[:3]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespaces", nargs=3, metavar="命名空间")
    args = parser.parse_args()
    if not hasattr(os, "setns"):
        parser.error("需要 Linux Python 3.12+（os.setns）")
    if len(set(args.namespaces)) != 3:
        parser.error("按 h1、nh1、nh2 顺序提供三个不同的命名空间")
    with ExitStack() as stack:
        sockets = [stack.enter_context(open_socket(name)) for name in args.namespaces]
        if tuple(sock.getsockname()[4] for sock in sockets) != (HOST_MAC, *NEXT_MACS):
            raise RuntimeError("主机 MAC 或命名空间顺序与配置不符")
        tests = boundary_cases()
        for test in tests:
            check_batch(sockets, [test])
        print(f"PASS：{len(tests)} 个报头、哈希键和丢弃用例", flush=True)
        flows = [case(f"TCP 源端口 {sport}，第 {repeat + 1} 帧", sport=sport, ttl=64 - repeat)
                 for sport in range(10000, 10500) for repeat in range(2)]
        for start in range(0, len(flows), 10):
            check_batch(sockets, flows[start:start + 10], quiet=0.05)
        counts = Counter(test.output for test in flows[::2])
        if set(counts) != {1, 2}:
            raise RuntimeError("流集合未覆盖两个出口")
        print(f"PASS：500 条 TCP 流各发 2 帧，逐帧 CRC32、MAC、TTL、校验和及负载一致", flush=True)
        print(f"本组样本：nh1 {counts[1]} 条流，nh2 {counts[2]} 条流（不代表任意流量均分）", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"FAIL：{error}") from error
