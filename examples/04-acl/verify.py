#!/usr/bin/env python3
"""用 BMv2 文件端口验证 ACL 输出及计数器，无需 root 或 Scapy。"""

import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import os
import re
import secrets
import signal
import socket
import struct
import subprocess
import tempfile
import time

MACS = [bytes.fromhex(f"00000000000{n}") for n in (1, 2, 3)]
IPS = [socket.inet_aton(f"10.0.0.{n}") for n in (1, 2, 3)]


@dataclass
class Case:
    label: str
    source: int
    frame: bytes
    output: int | None
    counter: int | None  # 5/10/20 是规则优先级，0 是 miss，None 是 ACL 前丢弃。


def checksum(data):
    data += b"\x00" if len(data) % 2 else b""
    value = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while value >> 16:
        value = (value & 0xffff) + (value >> 16)
    return (~value) & 0xffff


def frame(src, dst, protocol=6, sport=1234, dport=80, length=128,
          ttl=64, version=4, ihl=5, total_len=None, fragment=0,
          tcp_offset=5, udp_length=None, mac=None):
    options = b"\x01\x01\x01\x00" if ihl == 6 else b""
    tcp_options = b"\x01\x01\x01\x00" if tcp_offset == 6 else b""
    transport_size = 20 + len(tcp_options) if protocol == 6 else 8 if protocol in (1, 17) else 0
    marker = b"ACL:" + secrets.token_bytes(8)
    payload_size = length - 34 - len(options) - transport_size
    if payload_size < len(marker):
        raise ValueError("帧太短，无法容纳测试标识")
    payload = marker.ljust(payload_size, b"\x5a")
    if protocol == 6:
        segment = struct.pack("!HHIIBBHHH", sport, dport, 1, 0,
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
        pseudo = IPS[src - 1] + IPS[dst - 1] + struct.pack("!BBH", 0, protocol, len(segment))
        value = checksum(pseudo + segment)
        if protocol == 17 and value == 0:
            value = 0xffff
        segment = segment[:check_offset] + struct.pack("!H", value) + segment[check_offset + 2:]
    ip_length = 20 + len(options) + len(segment) if total_len is None else total_len
    header = struct.pack("!BBHHHBBH4s4s", version << 4 | ihl, 0, ip_length,
                         secrets.randbits(16), fragment, ttl, protocol, 0,
                         IPS[src - 1], IPS[dst - 1]) + options
    header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
    return (mac or MACS[dst - 1]) + MACS[src - 1] + b"\x08\x00" + header + segment


def cases():
    result = []

    def add(label, src, dst, output, counter, **kwargs):
        result.append(Case(label, src, frame(src, dst, **kwargs), output, counter))

    add("源端口 40000 的 SSH 例外", 3, 2, 2, 5, sport=40000, dport=22)
    add("源端口不符", 3, 2, None, 20, sport=40001, dport=22)
    add("源地址不符", 1, 2, None, 20, sport=40000, dport=22)
    add("目的地址不符", 3, 1, None, 20, sport=40000, dport=22)
    add("其他 SSH 请求", 2, 3, None, 20, dport=22)
    for protocol in (6, 17, 1, 253):
        add(f"h1 到 h3，协议 {protocol}", 1, 3, None, 10, protocol=protocol, dport=22)
    add("TCP 80 默认允许", 1, 2, 2, 0)
    add("返回方向不等于正向规则", 3, 1, 1, 0)
    add("UDP 22 不匹配 TCP 规则", 3, 2, 2, 0, protocol=17, sport=40000, dport=22)
    add("ICMP 使用零端口键", 1, 2, 2, 0, protocol=1)
    add("其他 IP 协议使用零端口键", 2, 1, 1, 0, protocol=253)
    add("源端口 22 不等于目的端口 22", 2, 1, 1, 0, sport=22, dport=40000)
    for length in (60, 128, 1514):
        add(f"UDP {length} 字节", 2, 1, 1, 0, protocol=17, length=length)
    for ttl in (0, 1):
        add(f"L2 转发不修改 TTL={ttl}", 1, 2, 2, 0, ttl=ttl)
    add("TCP 选项保持", 3, 2, 2, 5, sport=40000, dport=22, tcp_offset=6)
    add("ACL 允许但 L2 未命中", 3, 2, None, 5, sport=40000, dport=22,
        mac=bytes.fromhex("020000000099"))
    original = frame(2, 1, protocol=17)
    result.append(Case("帧尾填充保持并计入字节数", 2, original + b"\xa5" * 12, 1, 0))
    original = bytearray(frame(3, 2, sport=40000, dport=22))
    original[50] ^= 1
    result.append(Case("不验证 TCP 校验和", 3, bytes(original), 2, 5))
    for label, kwargs in (
        ("错误 IPv4 版本", {"version": 6}),
        ("IHL 小于 5", {"ihl": 4}),
        ("IPv4 选项", {"ihl": 6}),
        ("IP 总长度小于 20", {"total_len": 19}),
        ("IP 总长度超过帧", {"total_len": 500}),
        ("TCP 报头长度不足", {"total_len": 39}),
        ("TCP dataOffset 小于 5", {"tcp_offset": 4}),
        ("TCP dataOffset 超出 IP 负载", {"tcp_offset": 15, "total_len": 40}),
        ("UDP 报头长度不足", {"protocol": 17, "total_len": 27}),
        ("UDP length 小于 8", {"protocol": 17, "udp_length": 7}),
        ("UDP length 超出 IP 负载", {"protocol": 17, "udp_length": 500}),
        ("IPv4 首片", {"fragment": 0x2000}),
        ("IPv4 后续片", {"fragment": 1}),
    ):
        add(label, 3, 2, None, None, sport=40000, dport=22, **kwargs)
    original = frame(3, 2, sport=40000, dport=22)
    bad = bytearray(original)
    bad[24] ^= 1
    result.append(Case("错误 IPv4 校验和", 3, bytes(bad), None, None))
    for kind in (b"\x08\x06", b"\x86\xdd"):
        result.append(Case(f"非 IPv4 {kind.hex()}", 3, original[:12] + kind + original[14:], None, None))
    result.append(Case("VLAN", 3, original[:12] + b"\x81\x00\x00\x01" + original[12:], None, None))
    for length in (1, 13, 14, 33, 53):
        result.append(Case(f"截短至 {length} 字节", 3, original[:length], None, None))
    return result


def write_pcap(path, packets):
    with path.open("wb") as stream:
        stream.write(struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
        for index, packet in enumerate(packets):
            stream.write(struct.pack("<IIII", 1, index * 100, len(packet), len(packet)) + packet)


def read_pcap(path):
    data = path.read_bytes()
    # BMv2 在首次输出帧后才刷新文件，无输出的端口可能仍是空文件。
    if not data:
        return []
    if len(data) < 24 or data[:4] != b"\xd4\xc3\xb2\xa1":
        raise RuntimeError(f"不支持或不完整的 PCAP 文件：{path}")
    offset, result = 24, []
    while offset < len(data):
        if offset + 16 > len(data):
            raise RuntimeError(f"PCAP 记录头不完整：{path}")
        _, _, size, _ = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if offset + size > len(data):
            raise RuntimeError(f"PCAP 帧不完整：{path}")
        result.append(data[offset:offset + size])
        offset += size
    return result


def listener_port(process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("BMv2 文件端口实例启动失败")
        inodes = set()
        for fd in Path(f"/proc/{process.pid}/fd").iterdir():
            try:
                target = os.readlink(fd)
            except FileNotFoundError:
                continue
            if target.startswith("socket:["):
                inodes.add(target[8:-1])
        for family in ("tcp", "tcp6"):
            for line in Path(f"/proc/{process.pid}/net/{family}").read_text().splitlines()[1:]:
                fields = line.split()
                if fields[3] == "0A" and fields[9] in inodes:
                    return int(fields[1].rsplit(":", 1)[1], 16)
        time.sleep(0.05)
    raise RuntimeError("等待 Thrift 监听端口超时")


def verify(config, commands, work):
    tests = cases()
    ports = (0, 1, 2, 3)
    for port in ports:
        write_pcap(work / f"p{port}_in.pcap", [case.frame for case in tests if case.source == port])
    argv = ["simple_switch", "--thrift-port", "0", "--device-id", str(os.getpid()),
            "--use-files", "3", "--log-console", "--log-level", "debug",
            "--notifications-addr", f"ipc://{work}/notifications.ipc"]
    for port in ports:
        argv += ["-i", f"{port}@p{port}"]
    argv.append(str(config))
    process = None
    try:
        with (work / "switch.log").open("w") as log:
            process = subprocess.Popen(argv, cwd=work, stdout=log, stderr=subprocess.STDOUT)
        thrift_port = listener_port(process)

        def cli(text):
            result = subprocess.run(["simple_switch_CLI", "--thrift-port", str(thrift_port)],
                                    input=text, capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            with (work / "cli.log").open("a") as log:
                log.write(output)
            if result.returncode or re.search(r"Error|Invalid|Exception|Traceback|Unknown (?:command|syntax)", output, re.I):
                raise RuntimeError("CLI 操作失败：" + output)
            return output

        filtered = "\n".join(line for line in commands.read_text().splitlines()
                             if line.strip() and not line.lstrip().startswith("#")) + "\n"
        cli(filtered)
        if "Processing packet received" in (work / "switch.log").read_text():
            raise RuntimeError("配置未在文件端口开始送包前完成，请检查机器负载")
        dump = cli("table_dump MyIngress.acl\n")
        handles = {}
        for block in dump.split("Dumping entry ")[1:]:
            handle = int(block.split()[0], 16)
            match = re.search(r"Priority: (\d+)", block)
            if match:
                priority = int(match[1])
                if priority in handles:
                    raise RuntimeError("验证要求规则使用不同的优先级")
                handles[priority] = handle
        if set(handles) != {5, 10, 20}:
            raise RuntimeError(f"ACL 配置与测试策略不符：{handles}")

        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("BMv2 验证过程中退出")
            log_text = (work / "switch.log").read_text()
            # 文件读完只表示报文已入队，还须等流水线完成丢弃或发送。
            finished = re.findall(
                r"\[\d+\.0\] \[cxt 0\] (?:Transmitting packet of size|"
                r"Dropping packet at the end of (?:ingress|egress))", log_text)
            if ("Pcap reader: end of all input files" in log_text
                    and len(finished) == len(tests)):
                time.sleep(0.3)
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("等待文件端口处理完成超时")
        for port in ports:
            expected = Counter(case.frame for case in tests if case.output == port)
            actual = Counter(read_pcap(work / f"p{port}_out.pcap"))
            if actual != expected:
                raise RuntimeError(f"端口 {port} 输出不符，预期 {sum(expected.values())} 帧，实际 {sum(actual.values())} 帧")

        reads = "".join(f"counter_read MyIngress.acl_ctr {handles[p]}\n" for p in (5, 10, 20))
        output = cli(reads + "counter_read MyIngress.acl_miss 0\n")
        values = {(name, int(index)): (int(packets), int(size)) for name, index, size, packets in
                  re.findall(r"(MyIngress\.acl_(?:ctr|miss))\[(\d+)\]= \((\d+) bytes, (\d+) packets\)", output)}
        for priority in (5, 10, 20, 0):
            selected = [case for case in tests if case.counter == priority]
            expected = (len(selected), sum(len(case.frame) for case in selected))
            name, index = ("MyIngress.acl_ctr", handles[priority]) if priority else ("MyIngress.acl_miss", 0)
            if values.get((name, index)) != expected:
                raise RuntimeError(f"{name}[{index}] 计数不符：{values.get((name, index))}，预期 {expected}")
            print(f"PASS：{name}[{index}] = {expected[0]} packets, {expected[1]} bytes", flush=True)
        print(f"PASS：{len(tests)} 个 ACL 用例的输出端口、报文字节与计数器验证完成", flush=True)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path, help="编译后的 BMv2 JSON")
    parser.add_argument("--commands", type=Path,
                        default=Path(__file__).parent / "runtime/s1-commands.txt")
    parser.add_argument("--output-dir", type=Path, help="新建目录，保留 PCAP 和日志")
    args = parser.parse_args()
    config, commands = args.config.resolve(strict=True), args.commands.resolve(strict=True)

    def execute(work):
        try:
            verify(config, commands, work)
        except Exception:
            if (work / "switch.log").exists():
                print((work / "switch.log").read_text()[-4000:])
            raise

    if args.output_dir:
        work = args.output_dir.resolve()
        work.mkdir(parents=True, exist_ok=False)
        execute(work)
    else:
        with tempfile.TemporaryDirectory(prefix="p4-acl-verify.") as directory:
            execute(Path(directory))


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"FAIL：{error}") from error
