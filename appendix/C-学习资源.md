# 附录 C · 学习资源清单

> 精选对中文学习者友好的进阶资源。按类型分组，打 ⭐ 的是强烈推荐。

## C.1 官方规范与参考

- ⭐ [P4_16 Language Specification](https://p4.org/p4-spec/docs/P4-16-working-spec.html) —— 最权威的规范，长但值得通读
- [P4Runtime Specification](https://p4.org/p4-spec/p4runtime/main/P4Runtime-Spec.html)
- [PSA Specification](https://p4.org/p4-spec/docs/PSA.html)
- [PNA Specification](https://p4.org/p4-spec/docs/PNA.html)

## C.2 入门教程（英文）

- ⭐ [p4lang/tutorials](https://github.com/p4lang/tutorials) —— **必做**。官方手把手练习，涵盖 basic、calc、ECMP、NAT、源路由、INT 等
- [NSG ETH Zurich Advanced Networks Course](https://github.com/nsg-ethz/p4-learning) —— 苏黎世联邦理工的研究生课
- [ONF Learn](https://opennetworking.org/trainings/) —— 开放网络基金会的系列培训

## C.3 论文（按阅读顺序）

### 基础

- ⭐ Bosshart et al. **P4: Programming Protocol-Independent Packet Processors**, SIGCOMM CCR 2014
  —— 奠基论文，读完你就懂 P4 为什么设计成这样
- Jose et al. **Compiling Packet Programs to Reconfigurable Switches**, NSDI 2015

### 性能与实践

- Dang et al. **P4xos: Consensus as a Network Service**, ToN 2020 —— 用 P4 做 Paxos
- Li et al. **NetCache: Balancing Key-Value Stores with Fast In-Network Caching**, SOSP 2017

### 可测性与验证

- Stoenescu et al. **Vera: Verifying the Correctness of P4 Programs**, SIGCOMM 2018

### INT / 遥测

- ⭐ Kim et al. **In-band Network Telemetry via Programmable Dataplanes**, SIGCOMM 2015 demo
- Song. **Sel-INT: A Runtime Selective Testing Framework for INT**, APNet 2019

## C.4 代码仓库

### 交换机模拟

- [p4lang/behavioral-model](https://github.com/p4lang/behavioral-model) —— BMv2
- [jafingerhut/p4-guide](https://github.com/jafingerhut/p4-guide) —— 安装脚本 + 大量示例
- [nsg-ethz/p4-utils](https://github.com/nsg-ethz/p4-utils) —— Mininet + P4 的辅助库

### 控制平面

- [p4lang/p4runtime-shell](https://github.com/p4lang/p4runtime-shell)
- [onosproject/onos](https://github.com/onosproject/onos) —— 开源 SDN 控制器，支持 P4 设备

### 编译器

- [p4lang/p4c](https://github.com/p4lang/p4c) —— 官方编译器（有 bmv2、ebpf、dpdk 等后端）
- [p4lang/tools](https://github.com/p4lang/tools) —— 各类 P4 工具

### 研究与应用

- [p4lang/p4app-switchML](https://github.com/p4lang/p4app-switchML) —— 在网络里做分布式机器学习聚合
- [opennetworkinglab/fabric-tna](https://github.com/opennetworkinglab/fabric-tna) —— 生产级 TNA fabric
- [ONFLabs/sdnctx-p4](https://github.com/) —— 各种 P4 应用示例

## C.5 视频课程

- [P4 Developer Day](https://www.youtube.com/@p4lang) —— 每年一届，slide + 录像都公开
- [ONF P4 Workshop](https://opennetworking.org/events/) —— 同上，更实操
- Stanford CS344（不常开）—— **Programmable Network Systems**

## C.6 中文社区与资源

> 国内资源相对少，但可关注：

- **知乎专栏**：「软件定义网络 SDN」「可编程网络」等专栏会零星更新
- **公众号**：「网络技术联盟站」「SDNLAB」「Linux 后端开发工程技术」偶有 P4 文章
- **B 站**：搜索 "P4 编程"、"可编程交换机" 有少量入门视频
- **学术团队**：国防科大、清华、浙大、复旦、北邮等都有相关研究组发表论文，代码部分开源

## C.7 推荐配套书籍

没有一本中文 P4 专著可推荐（这也是我写这个仓库的动因之一）。英文：

- **《P4 Programming for Reconfigurable Switches》** - Vladimir Gurevich, 2020（非正式电子书）
- 《Software-Defined Networks: A Systems Approach》 - Peterson, Cascone, O'Connor, Vachuska, Davie —— 不完全是 P4，但把 P4 在 SDN 里的角色讲得最清楚

## C.8 实际部署 / 商业项目

- **Intel Tofino** —— 目前唯一量产的线速 P4 ASIC
- **ONF SDN Fabric** —— 基于 Tofino 的生产级 fabric
- **Aruba CX10000** —— 智能网卡 + P4 在网络安全中的应用
- **AWS Scalable Reliable Datagram (SRD)** —— 虽未公开细节，但明确使用了 P4 类的可编程管线

## C.9 会议与活动

| 会议 | 主题 | 说明 |
| ---- | ---- | ---- |
| SIGCOMM | 网络顶会 | P4 系列论文主阵地 |
| NSDI | 系统网络 | 很多 P4 系统论文 |
| HotNets / APNet | 新方向 | P4 新点子 |
| P4 Workshop | P4 专场 | 每年一届 |
| ONF Connect | SDN 社区 | 产业导向 |

## C.10 如何问问题

遇到解决不了的问题，按推荐优先级：

1. **p4lang GitHub Issues**（对应仓库）—— 官方开发者答
2. **[p4lang community mailing list](https://lists.p4.org/)** —— 讨论氛围好
3. **Stack Overflow** 的 `p4` 标签 —— 冷但靠谱
4. **本仓库 Issues** —— 我会尽量答中文

---

## 收藏清单（给忙人）

如果你只能收藏 5 个：

1. ⭐ [p4lang/tutorials](https://github.com/p4lang/tutorials)
2. ⭐ [P4_16 Spec](https://p4.org/p4-spec/docs/P4-16-working-spec.html)
3. ⭐ [jafingerhut/p4-guide](https://github.com/jafingerhut/p4-guide)
4. ⭐ [p4lang/p4c](https://github.com/p4lang/p4c)
5. ⭐ **本仓库** 😉
