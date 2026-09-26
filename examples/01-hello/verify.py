#!/usr/bin/env python3
"""在两个主机命名空间内收发原始以太帧，验证 Hello P4 的反射行为。"""

import argparse
from contextlib import ExitStack
import os
import secrets
import select
import socket
import time


def open_socket(namespace):
    # 套接字创建后仍属于原网络命名空间，恢复线程的命名空间不会改变它。
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


def check_frame(sockets, source, length):
    marker = b"HELLO-P4:" + secrets.token_bytes(16)
    header = b"\xff" * 6 + sockets[source].getsockname()[4] + bytes.fromhex("88b5")
    frame = header + marker + secrets.token_bytes(length - len(header) - len(marker))
    if sockets[source].send(frame) != len(frame):
        raise RuntimeError("未能发送完整测试帧")

    reflected = 0
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        ready, _, _ = select.select(sockets, [], [], max(0, deadline - time.monotonic()))
        for sock in ready:
            received, address = sock.recvfrom(65535)
            # 排除本机发包记录；随机标识用于区分测试帧与背景流量。
            if address[2] == socket.PACKET_OUTGOING or marker not in received:
                continue
            if sock is not sockets[source]:
                raise RuntimeError(f"h{source + 1} 的测试帧出现在另一主机")
            if received != frame:
                raise RuntimeError(f"h{source + 1} 收到的反射帧内容不一致")
            reflected += 1
            if reflected > 1:
                raise RuntimeError(f"h{source + 1} 收到重复反射帧")
            # 收到反射后继续观察，以发现另一端口上的副本。
            deadline = time.monotonic() + 0.3
    if reflected != 1:
        raise RuntimeError(f"h{source + 1} 未收到 {length} 字节的反射帧")
    print(f"PASS：h{source + 1}，{length} 字节，反射帧一致；观察窗口内另一主机未收到测试帧",
          flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("namespaces", nargs=2, metavar="命名空间")
    args = parser.parse_args()
    if not hasattr(os, "setns"):
        parser.error("需要 Linux 上的 Python 3.12 或更高版本（os.setns）")

    with ExitStack() as stack:
        sockets = [stack.enter_context(open_socket(name)) for name in args.namespaces]
        for source in range(2):
            for length in (60, 128, 1514):
                check_frame(sockets, source, length)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"FAIL：{error}") from error
