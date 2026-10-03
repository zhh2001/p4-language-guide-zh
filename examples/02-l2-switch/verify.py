#!/usr/bin/env python3
"""在三个主机命名空间内，逐帧验证静态 L2 转发、泛洪与回源抑制。"""

import argparse
from contextlib import ExitStack
import os
import secrets
import select
import socket
import time


def open_socket(namespace):
    # 在目标命名空间创建套接字后恢复。套接字仍属于目标命名空间。
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


def check_frame(sockets, source, destination, receivers, length, label):
    marker = b"L2-P4:" + secrets.token_bytes(16)
    header = destination + sockets[source].getsockname()[4] + bytes.fromhex("88b5")
    frame = header + marker + secrets.token_bytes(length - len(header) - len(marker))
    if sockets[source].send(frame) != len(frame):
        raise RuntimeError("未能发送完整测试帧")

    counts = [0] * len(sockets)
    expected = [int(index in receivers) for index in range(len(sockets))]
    deadline = time.monotonic() + (3 if receivers else 0.3)
    while time.monotonic() < deadline:
        ready, _, _ = select.select(sockets, [], [], max(0, deadline - time.monotonic()))
        for sock in ready:
            received, address = sock.recvfrom(65535)
            if address[2] == socket.PACKET_OUTGOING or marker not in received:
                continue
            index = sockets.index(sock)
            if received != frame:
                raise RuntimeError(f"{label}：h{index + 1} 收到的帧内容不一致")
            counts[index] += 1
            if counts[index] > expected[index]:
                raise RuntimeError(f"{label}：h{index + 1} 收到多余副本，计数 {counts}")
            if counts == expected:
                # 继续观察其他端口及重复副本；不能在收到首帧时就判为成功。
                deadline = time.monotonic() + 0.3
    if counts != expected:
        raise RuntimeError(f"{label}：预期各主机接收 {expected}，实际 {counts}")
    print(f"PASS：{label}，{length} 字节，接收计数 {counts}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespaces", nargs=3, metavar="命名空间")
    args = parser.parse_args()
    if not hasattr(os, "setns"):
        parser.error("需要 Linux Python 3.12+（os.setns）")
    if len(set(args.namespaces)) != 3:
        parser.error("需要三个不同的主机命名空间，按端口 1、2、3 的顺序传入")

    with ExitStack() as stack:
        sockets = [stack.enter_context(open_socket(name)) for name in args.namespaces]
        addresses = [sock.getsockname()[4] for sock in sockets]
        wanted = [bytes.fromhex(f"00000000000{number}") for number in (1, 2, 3)]
        if addresses != wanted:
            raise RuntimeError("主机 MAC 或命名空间顺序与静态表项不符")
        for source in range(3):
            for destination in range(3):
                if source == destination:
                    continue
                for length in (60, 128, 1514):
                    check_frame(sockets, source, addresses[destination], {destination},
                                length, f"单播 h{source + 1} → h{destination + 1}")
            check_frame(sockets, source, addresses[source], set(), 60,
                        f"h{source + 1} 目的端口等于入端口")
            others = set(range(3)) - {source}
            check_frame(sockets, source, bytes.fromhex("020000000099"), others, 128,
                        f"h{source + 1} 未知单播泛洪")
            check_frame(sockets, source, b"\xff" * 6, others, 60,
                        f"h{source + 1} 广播")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"FAIL：{error}") from error
