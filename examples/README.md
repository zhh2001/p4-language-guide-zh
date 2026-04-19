# 示例代码

> 所有示例都基于 **V1Model + BMv2**（`vss/` 是规范参考，不可运行）。按难度递进。

| 目录 | 难度 | 描述 | 相关章节 |
| ---- | ---- | ---- | -------- |
| [`01-hello`](./01-hello) | ⭐ | 报文反射，最小可跑 | docs/03 |
| [`02-l2-switch`](./02-l2-switch) | ⭐⭐ | L2 静态转发 + 广播 | docs/08, 11 |
| [`03-ipv4-router`](./03-ipv4-router) | ⭐⭐⭐ | IPv4 LPM 路由 + MAC 改写 + TTL + 校验和 | docs/06-11 |
| [`04-acl`](./04-acl) | ⭐⭐⭐ | 5-tuple ternary ACL + 计数器 | docs/08, 12 |
| [`05-ecmp`](./05-ecmp) | ⭐⭐⭐⭐ | CRC32 哈希做等价多路径 | docs/11, 12 |
| [`vss`](./vss) | 参考 | 规范附录 VSS 完整示例 | docs/10 |

## 通用前置

```bash
# 验证环境
p4c --version             # ≥ 1.2.x
simple_switch --version   # ≥ 1.15
simple_switch_CLI --version
```

环境没装好？回 [docs/01-环境搭建.md](../docs/01-环境搭建.md)。

## 通用目录结构

每个示例（除 vss）都按这个结构组织：

```text
<example-name>/
├── README.md                  # 背景、拓扑、验证方法
├── <prog>.p4                  # P4 源码
├── build.sh                   # 封装 p4c 调用
├── run.sh                     # 一键起网络 + 加载表 + 测试
└── runtime/
    ├── s1-commands.txt        # Thrift CLI 格式
    └── ctrl.py  (可选)        # P4Runtime / gRPC 客户端
```

## 如果 `run.sh` 报错

- 缺 `hping3`：`sudo apt install hping3`，或用内置的 scapy 回退
- 没有 `simple_switch`：回 [docs/01](../docs/01-环境搭建.md) 重装
- 权限不够：所有 `run.sh` 都要 `sudo`

## 想自己写示例？

欢迎 PR。新示例请保持本目录的规范（README + build.sh + run.sh）。标明测试所用的 `p4c` 版本和 BMv2 版本。
