<div align="center">

# P4 语言中文教程

**一本从入门到精通的 P4_16 中文指南 · A Chinese Guide to P4_16 Programming**

[![P4 Version](https://img.shields.io/badge/P4-P4__16-blue)](https://p4.org/p4-spec/docs/P4-16-working-spec.html)
[![License](https://img.shields.io/badge/License-MIT-green)](./LICENSE)
[![Target](https://img.shields.io/badge/Target-BMv2%20%7C%20v1model-orange)](https://github.com/p4lang/behavioral-model)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](#-贡献指南)

[📚 开始学习](./docs/01-环境搭建.md) · [🧪 动手实验](./examples) · [📖 术语表](./appendix/B-术语表.md) · [❓ FAQ](./appendix/D-常见问题.md)

</div>

---

## ✨ 项目特色

- 🇨🇳 **完全中文** — 覆盖 P4_16 规范 + V1Model + P4Runtime + BMv2 工具链
- 🧭 **清晰学习路径** — 从零基础到能写出自己的数据平面程序
- 🧪 **可运行示例** — 每一章都配有在 BMv2/Mininet 上可直接复现的代码
- 🎯 **贴近工程实践** — 不止讲语言，还讲架构、控制平面、调试、常见陷阱
- 🆓 **MIT 协议** — 自由使用、自由传播

## 👥 适合人群

- SDN、可编程网络、数据中心方向的研究生与科研工作者
- 对网络转发平面、智能网卡、可编程交换机感兴趣的工程师
- 准备做 P4 相关课题、毕设、论文复现的同学
- 想从"配置 CLI"升级到"编程数据平面"的传统网工

## 📍 学习路径

推荐按顺序阅读，每一阶段都对应一组可动手验证的示例。

```text
┌──────────────┐      ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
│  第一阶段    │ ──▶ │  第二阶段    │ ──▶ │  第三阶段    │ ──▶ │  第四阶段    │
│  入门与环境  │      │  语言核心    │      │  架构与实战  │      │  控制平面    │
├──────────────┤      ├──────────────┤      ├──────────────┤      ├──────────────┤
│ 01 环境搭建  │      │ 04 语法基础  │      │ 10 架构与包  │      │ 14 BMv2 工具 │
│ 02 P4 概述   │      │ 05 类型系统  │      │ 11 V1Model   │      │ 15 P4Runtime │
│ 03 Hello P4  │      │ 06 Parser    │      │ 12 Extern    │      │ 16 PSA / TNA │
│              │      │ 07 控制块    │      │ 13 注解进阶  │      │              │
│              │      │ 08 表        │      │              │      │              │
│              │      │ 09 Deparser  │      │              │      │              │
└──────────────┘      └──────────────┘      └──────────────┘      └──────────────┘
       │                     │                     │                     │
       ▼                     ▼                     ▼                     ▼
   hello 示例          L2 交换机           IPv4 路由 + ACL         ECMP + Runtime
```

## 📑 章节目录

### 第一阶段 · 入门与环境

| # | 章节 | 你将学到 |
| - | ---- | -------- |
| 01 | [环境搭建](./docs/01-环境搭建.md) | 用 Docker / apt / 源码安装 P4 工具链，并完成自检 |
| 02 | [P4 概述与核心概念](./docs/02-P4概述.md) | PISA 架构、协议无关转发、P4 的生态位 |
| 03 | [第一个 P4 程序](./docs/03-第一个P4程序.md) | 在 BMv2 上跑通 Hello P4，建立流水线直觉 |

### 第二阶段 · 语言核心

| # | 章节 | 你将学到 |
| - | ---- | -------- |
| 04 | [语法基础](./docs/04-语法基础.md) | 标识符、字面量、注释、运算符、语句 |
| 05 | [类型系统](./docs/05-类型系统.md) | `bit`/`int`/`header`/`struct`/`union`/`stack` |
| 06 | [Parser 解析器](./docs/06-Parser解析器.md) | 状态机、`select`、`extract`、`verify`、子解析器 |
| 07 | [控制块与动作](./docs/07-控制块与动作.md) | `control` 结构、`action`、`apply` |
| 08 | [匹配-动作表](./docs/08-匹配动作表.md) | `table`、`key`、`match_kind`、`entries`、优先级 |
| 09 | [Deparser 反解析器](./docs/09-Deparser反解析器.md) | `emit` 语义与报文重组 |

### 第三阶段 · 架构与实战

| # | 章节 | 你将学到 |
| - | ---- | -------- |
| 10 | [架构与包](./docs/10-架构与包.md) | 为什么有 Architecture、如何读架构文件 |
| 11 | [V1Model 架构详解](./docs/11-V1Model架构.md) | `standard_metadata`、六大块、BMv2 行为 |
| 12 | [外部对象 Extern](./docs/12-外部对象Extern.md) | `counter`/`meter`/`register`/`hash`/`digest` |
| 13 | [注解与高级特性](./docs/13-注解与高级特性.md) | `@name`、`@atomic`、`static_assert`、泛型 |

### 第四阶段 · 编译运行与控制平面

| # | 章节 | 你将学到 |
| - | ---- | -------- |
| 14 | [BMv2 编译与运行](./docs/14-BMv2编译与运行.md) | `p4c-bm2-ss` → `simple_switch` → Mininet |
| 15 | [P4Runtime 控制平面](./docs/15-P4Runtime控制平面.md) | `p4info`、gRPC、下发表项的 Python 客户端 |
| 16 | [PSA 与 TNA 简介](./docs/16-PSA与TNA简介.md) | 面向生产设备的可移植与 Tofino 架构 |

### 附录

- [A · 核心库 `core.p4` 逐行解析](./appendix/A-核心库core.p4解析.md)
- [B · 术语表（中英对照）](./appendix/B-术语表.md)
- [C · 学习资源清单](./appendix/C-学习资源.md)
- [D · 常见问题与调试技巧](./appendix/D-常见问题.md)

## 🧪 示例代码

所有示例都放在 [`examples/`](./examples)，可独立编译运行，并且按难度递进：

| 目录 | 难度 | 说明 |
| ---- | ---- | ---- |
| [`examples/01-hello`](./examples/01-hello) | ⭐ | 最小可跑的 P4 程序（报文反射） |
| [`examples/02-l2-switch`](./examples/02-l2-switch) | ⭐⭐ | 静态 MAC 转发的 L2 交换机 |
| [`examples/03-ipv4-router`](./examples/03-ipv4-router) | ⭐⭐⭐ | 基于 LPM 的 IPv4 路由器（TTL、校验和、MAC 改写） |
| [`examples/04-acl`](./examples/04-acl) | ⭐⭐⭐ | 基于三元组的访问控制 |
| [`examples/05-ecmp`](./examples/05-ecmp) | ⭐⭐⭐⭐ | 使用哈希做等价多路径负载均衡 |
| [`examples/vss`](./examples/vss) | ⭐⭐⭐ | 官方 Very Simple Switch 完整示例 |

## 🛠️ 推荐工具栈

| 用途 | 推荐 |
| ---- | ---- |
| 编译器 | `p4c`（`p4c-bm2-ss` 后端） |
| 软件目标 | BMv2 `simple_switch` / `simple_switch_grpc` |
| 拓扑仿真 | Mininet |
| 控制平面 | P4Runtime（gRPC）+ Python 客户端 |
| 抓包 | `tcpdump`、Wireshark（含 P4 插件） |
| IDE | VS Code + [`p4-analyzer`](https://marketplace.visualstudio.com/items?itemName=p4lang.p4-analyzer) |

一键起环境：见 [01-环境搭建 · Docker 方式](./docs/01-环境搭建.md#方式一docker推荐)。

## 🗣️ 我为什么写这份教程

国内做 SDN / 可编程网络的同学越来越多，但：

- 官方文档是英文的硬核规范，新人读起来像读法律条文；
- 零散的博客质量参差，常有概念错误（例如混淆 P4_14 与 P4_16）；
- 不少教程只讲语法，却不讲 V1Model 的真实语义，导致"抄得出来、跑不起来"。

本仓库希望把 **规范 + 实践 + 中文直觉** 合在一起，让你少走弯路。

## 🤝 贡献指南

欢迎任何形式的贡献！

- 发现错别字、技术错误 → 直接提 PR
- 想补充示例、加入新架构（TNA、DPDK、eBPF 后端）→ 开 Issue 讨论
- 翻译表述有更好的中文习惯 → 欢迎改写

提 PR 前请阅读：

1. 每章保持 **可独立阅读**；
2. 示例代码 **必须能编译通过** 并注明测试目标（`p4c` 版本、架构）；
3. 术语统一参考 [附录 B · 术语表](./appendix/B-术语表.md)。

## 📜 License

本项目基于 [MIT License](./LICENSE) 开源。引用示例时欢迎注明出处。

## ⭐ 如果对你有帮助

- 点个 **Star** 是对作者最大的鼓励
- 转发给同实验室的同学，让更多中文学习者少走弯路
- 在你的论文、课件里引用本仓库，也欢迎告诉我

> 建议先从 [01 · 环境搭建](./docs/01-环境搭建.md) 起步。遇到任何卡点，到 [Issues](../../issues) 里留言，我会认真答复。
