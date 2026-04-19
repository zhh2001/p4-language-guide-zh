# 附录 B · 术语表（中英对照）

> 本表按英文字母顺序排列。翻译不求"大而全"，求"大家都能看懂、用着顺手"。读英文论文时对照查用即可。

## A

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Action | 动作 | 数据平面的代码片段 |
| Action data | 动作数据 | 控制平面下发的 action 参数 |
| Action profile / selector | 动作配置 / 动作选择器 | 做 ECMP / LAG 的结构 |
| Annotation | 注解 | `@name`、`@hidden` 等 |
| Architecture | 架构 / 体系 | 描述芯片流水线形状的抽象 |
| ASIC | 专用集成电路 | Tofino 等可编程交换芯片 |

## B

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Base | 底值 | `hash()` 的起始值 |
| Bit string | 位串 | `bit<W>` 类型 |
| BMv2 | 行为模型 v2 | P4 官方软件交换机 |

## C

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Checksum | 校验和 | IPv4/TCP/UDP |
| Clone | 克隆 | 报文复制 |
| Constructor parameter | 构造参数 | 实例化时传入，编译期固化 |
| Control block | 控制块 | `control { ... }` |
| Control plane | 控制平面 | 下发表项的软件 |
| Core library | 核心库 | `core.p4` |
| Counter | 计数器 | 统计报文/字节数 |
| CPU port | CPU 端口 | 与控制平面通信的专用端口 |

## D

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Data plane | 数据平面 | 真正处理报文的硬件/软件 |
| Deparser | 反解析器 | 把 header 写回字节流 |
| Default action | 默认动作 | 未命中时执行 |
| Digest | 摘要 | 发给控制平面的轻量消息 |
| Direction | 方向 | `in`/`out`/`inout` |

## E

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| ECMP | 等价多路径 | 典型的哈希负载均衡 |
| Egress | 出方向 / 出向 | 也指出方向处理阶段 |
| Election id | 选举 id | P4Runtime 选主用 |
| Entry | 表项 | table 里的一条规则 |
| `emit` | 写出 | 把 header 放到出包缓冲区 |
| enum | 枚举 | `enum { ... }` |
| Error | 错误 | parser `verify` 用 |
| `extern` | 外部对象 | 由目标提供的 API |
| `extract` | 提取 | 从字节流取出 header |

## F

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Fan-in / Fan-out | 扇入 / 扇出 | 硬件路径概念 |
| FQN (Fully Qualified Name) | 完全限定名 | 控制平面看到的名字 |
| Flow | 流 | 5-tuple 或自定义 |

## G

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| gRPC | gRPC | P4Runtime 的传输层 |
| Generics | 泛型 | `<T>`、`<H, M>` |

## H

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Hash | 哈希 | ECMP / 流 id 生成 |
| Header | 报头 | P4 的核心类型 |
| Header stack | 报头栈 | `H[N]` |
| Header union | 报头联合体 | `header_union` |
| Hit | 命中 | table 查到了匹配项 |

## I

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| IHL | 网际报头长度 | IPv4 字段，单位 4 字节 |
| Implicit cast | 隐式转换 | P4 里很少 |
| Ingress | 入方向 / 入向 |  |
| INT | 带内网络遥测 | 由 P4 激活的测量技术 |
| Invalid header | 无效报头 | `setInvalid()` 后或从未 setValid |
| Instantiation | 实例化 | 对 package/control 进行 `name()` |

## L

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Label | 标签 | `select` 里的每一行 |
| Learning | 学习 | 数据平面把事件送控制平面的典型模式 |
| Lookahead | 预提取 / 偷看 | `packet.lookahead<T>()` |
| LPM | 最长前缀匹配 | IPv4 路由 |
| Lvalue | 左值 | 可被赋值的变量 |

## M

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Main package | 顶层包 | `V1Switch(...) main` |
| Match-Action | 匹配-动作 | P4 的核心范式 |
| Match kind | 匹配类型 | `exact`/`ternary`/`lpm` |
| Metadata | 元数据 | 流水线里传递的辅助信息 |
| Meter | 计量器 / 令牌桶 | 限速 |
| Miss | 未命中 | table 没查到 |
| Mirror | 镜像 | 通常通过 clone 实现 |
| Multicast group | 多播组 | TM 配置 |

## N

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Nanomsg | Nanomsg | BMv2 的事件总线 |
| `NoAction` | 空动作 | core.p4 定义 |

## P

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Package | 包 | 装配块的容器 |
| Packet | 报文 / 数据包 |  |
| Packet-in / Packet-out | 上送包 / 下注包 | 控制平面与数据平面直接交换报文 |
| P4Info | P4 元信息 | 编译产物，给控制平面看 |
| P4Runtime | P4 运行时 | 标准化的南向 gRPC API |
| Parser | 解析器 | 状态机 |
| PCAP | 报文捕获文件 | 抓包格式 |
| Pipeline | 流水线 | 数据平面的处理链 |
| PISA | 协议无关交换架构 | P4 的硬件抽象 |
| PNA | 可移植 NIC 架构 | 智能网卡标准 |
| PSA | 可移植交换机架构 | P4.org 标准 |
| Priority | 优先级 | ternary 表项用 |
| Protocol-independent | 协议无关 | P4 的 "P" |

## R

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Recirculate | 重循环 | egress 回 ingress |
| Register | 寄存器 | 有状态数组 |
| Resubmit | 重新提交 | ingress 内重做 |
| Reject | 拒绝 | parser 终态 |
| Runtime | 运行时 | 一般指 P4Runtime |

## S

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| SDN | 软件定义网络 |  |
| `select` | 选择 | parser 里的分发 |
| `setValid` / `setInvalid` | 设有效 / 设无效 |  |
| `simple_switch` | BMv2 软件交换机 |  |
| SMAC / DMAC | 源 MAC / 目的 MAC |  |
| Stage | 流水级 | 硬件约束 |
| Standard metadata | 标准元数据 | V1Model 里 |
| State | 状态 | parser 的节点 |
| Static assert | 编译期断言 |  |
| Sub-parser | 子解析器 | parser 里 apply 另一个 parser |

## T

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Table | 表 | match-action 单元 |
| TCAM | 三态内容寻址存储器 | ACL / LPM 的硬件基础 |
| Ternary | 三元组 / 三态 | `value &&& mask` |
| TNA | Tofino Native Architecture | Intel Tofino 架构 |
| TTL | 生存时间 | IPv4/IPv6 字段 |
| Tuple | 元组 | `tuple<bit<32>, bool>` |

## V

| 英文 | 中文 | 备注 |
| ---- | ---- | ---- |
| Validity bit | 有效位 | header 的隐藏字段 |
| Value set | 值集合 | `value_set<T>` |
| Varbit | 变长位串 | `varbit<W>` |
| VC / CC | Verify / Compute Checksum | V1Model 两个校验和块 |
| VLAN | 虚拟局域网 |  |
| V1Model | V1 模型架构 | BMv2 常用 |
| VSS | Very Simple Switch | 规范里的教学架构 |
| VXLAN | 虚拟可扩展局域网 |  |

## 扩展阅读

- [P4_16 规范官方术语表](https://p4.org/p4-spec/docs/P4-16-working-spec.html#sec-glossary)
- [RFC 8930 YANG Data Model for P4Runtime](https://datatracker.ietf.org/doc/html/rfc8930)（可选）
