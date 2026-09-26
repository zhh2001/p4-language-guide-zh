# 示例代码

> 所有示例都基于 **V1Model + BMv2**（`vss/` 是规范参考，不可运行）。按难度递进。

| 目录                                 | 难度 | 描述                                    | 相关章节    |
| ------------------------------------ | ---- | --------------------------------------- | ----------- |
| [`01-hello`](./01-hello)             | ⭐    | 报文反射，最小可跑                      | docs/03     |
| [`02-l2-switch`](./02-l2-switch)     | ⭐⭐   | L2 静态转发 + 广播                      | docs/08, 11 |
| [`03-ipv4-router`](./03-ipv4-router) | ⭐⭐⭐  | IPv4 LPM 路由 + MAC 改写 + TTL + 校验和 | docs/06-11  |
| [`04-acl`](./04-acl)                 | ⭐⭐⭐  | 5-tuple ternary ACL + 计数器            | docs/08, 12 |
| [`05-ecmp`](./05-ecmp)               | ⭐⭐⭐⭐ | CRC32 哈希做等价多路径                  | docs/11, 12 |
| [`vss`](./vss)                       | 参考 | 规范附录 VSS 完整示例                   | docs/10     |

## 通用前置

先按 [第 1 章](../docs/01-环境搭建.md#14-环境自检)检查环境。在仓库根目录执行下列命令，可验证 Hello P4 编译及 BMv2 报文反射，脚本退出时自动清理本次创建的资源：

```bash
sudo bash examples/check-env.sh
```

编号示例的 `run.sh` 使用 network namespace 和 veth，并未调用 Mininet。后续需要下发表项的示例还依赖 `simple_switch_CLI`，可先用 `simple_switch_CLI --help` 检查客户端能否启动。

## 通用目录结构

每个示例（除 vss）都按这个结构组织：

```text
<example-name>/
├── README.md                  # 背景、拓扑、验证方法
├── <prog>.p4                  # P4 源码
├── build.sh                   # 封装 p4c 调用
├── run.sh                     # 一键起网络 + 加载表 + 测试
└── runtime/                   # 按需提供；01-hello 无此目录
    ├── s1-commands.txt        # Thrift CLI 格式
    └── ctrl.py  (可选)        # P4Runtime / gRPC 客户端
```

## 如果 `run.sh` 报错

- 缺 `hping3`：`sudo apt install hping3`，或用内置的 scapy 回退
- 没有 `simple_switch`：先按 [第 1 章](../docs/01-环境搭建.md#15-常见问题的定位顺序)检查安装路径与环境变量
- 权限不够：所有 `run.sh` 都要 `sudo`

## 想自己写示例？

欢迎 PR。新示例请保持本目录的规范（README + build.sh + run.sh）。标明测试所用的 `p4c` 版本和 BMv2 版本。
