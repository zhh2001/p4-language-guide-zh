# 附录 C · 学习资源清单

## C.1 官方规范与参考

| 资料                                                                                                                                        | 本教程采用的版本    | 查阅用途                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | --------------------------------------------------- |
| [P4<sub>16</sub> Language Specification](https://p4.org/wp-content/uploads/sites/53/2024/10/P4-16-spec-v1.2.5.html)                         | 1.2.5               | 类型、表达式、Parser、Control、表和核心库的语言语义 |
| [P4Runtime Specification](https://p4lang.github.io/p4runtime/spec/v1.4.1/P4Runtime-Spec.html)                                               | 1.4.1               | P4Info、实体读写、仲裁、流水线配置与异步消息        |
| [PSA Specification](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PSA-v1.2.html)                                                  | 1.2                 | 可移植交换机架构的接口、报文路径与 extern 行为      |
| [PNA Specification](https://p4.org/wp-content/uploads/sites/53/p4-spec/docs/PNA-v0.7.html)                                                  | 0.7，工作草案       | 面向网卡的可编程块、接口与处理流程                  |
| [BMv2 `simple_switch` 说明](https://github.com/p4lang/behavioral-model/blob/2bdd0b7b2b2ae89faf2720f2158e9842bc6d2dd2/docs/simple_switch.md) | 实测提交 `2bdd0b7b` | V1Model 元数据、丢弃、复制、重提交等目标行为        |

上表列出本教程采用的规范版本，其他版本可从 [P4 规范目录](https://p4.org/specifications/)查找。记录实验环境时，分别写明语言规范版本、架构版本与 `p4c --version` 的输出。

查阅顺序可以按问题来定：语法与类型看语言规范，元数据和报文路径看架构文档，具体支持范围看编译器及目标说明。遇到差异时，再用最小程序和报文测试核对实现。

## C.2 入门教程与练习

- [p4lang/tutorials](https://github.com/p4lang/tutorials/tree/134fcfa1c9e40eccdc6ae8f835084273902e29de)：P4 社区维护的练习与讲义，采用 V1Model，适合配合本教程的 BMv2 环境学习。本节练习目录以提交 `134fcfa1` 为准。
- [nsg-ethz/p4-learning](https://github.com/nsg-ethz/p4-learning/tree/0ddba187f207e24a8a614f5d1abf8bc11998c9d3)：ETH Zürich NSG 整理的 P4<sub>16</sub> 示例、练习和课件，部分材料来自 Advanced Topics in Communication Networks 课程，配套 P4-Utils 组织实验。这里引用提交 `0ddba187`，环境要求见该版本的 README。

完成本仓库的报文反射和 IPv4 路由实验后，可按以下顺序做 `p4lang/tutorials` 的练习。目录均位于上述版本的 `exercises/` 下：

| 练习目录                | 练习内容                                               | 对照本教程              |
| ----------------------- | ------------------------------------------------------ | ----------------------- |
| `basic`、`basic_tunnel` | IPv4 转发、自定义隧道头的解析与封装                    | 第 3、6、8、9 章        |
| `calc`、`load_balance`  | 自定义协议、动作和哈希选路                             | 第 7、12 章及 ECMP 示例 |
| `p4runtime`             | 用控制程序配置流水线与表项                             | 第 15 章                |
| `mri`                   | Multi-Hop Route Inspection，记录经过的交换机和队列信息 | 报头栈、元数据及遥测    |

`mri` 用报头栈记录逐跳信息，是简化的 INT 教学练习。INT 的格式定义与采集机制见 [C.3 节](#c3-论文与阅读重点)列出的规范目录。使用已有环境时，可按[第 1 章](../docs/01-环境搭建.md)的方法检查编译器、目标程序及 Python 依赖。

## C.3 论文与阅读重点

阅读论文时，可先梳理报文处理流程与软硬件分工，再结合原型平台和实验条件分析结果。

### 基础

- Pat Bosshart 等：[P4: programming protocol-independent packet processors](https://doi.org/10.1145/2656877.2656890)，*ACM SIGCOMM Computer Communication Review*，44(3): 87–95，2014。介绍协议无关、目标无关与可重配置的设计动机，反映了 P4 语言早期的设计。
- Lavanya Jose 等：[Compiling Packet Programs to Reconfigurable Switches](https://www.usenix.org/conference/nsdi15/technical-sessions/presentation/jose)，*NSDI 2015*。讨论如何在数据与控制依赖、存储容量等约束下，将逻辑表映射到硬件流水级。

### 网内计算与系统实践

- Xin Jin 等：[NetCache: Balancing Key-Value Stores with Fast In-Network Caching](https://doi.org/10.1145/3132747.3132764)，*SOSP 2017*，121–136。关注热点键值缓存、缓存一致性及交换机与服务器的分工。
- Huynh Tu Dang 等：[P4xos: Consensus as a Network Service](https://doi.org/10.1109/TNET.2020.2992106)，*IEEE/ACM Transactions on Networking*，28(4): 1726–1738，2020。研究用可编程交换机加速 Paxos，可重点阅读协议角色的分工、状态存储与故障处理。

### 程序验证

- Radu Stoenescu 等：[Debugging P4 Programs with Vera](https://doi.org/10.1145/3230543.3230548)，*SIGCOMM 2018*，518–532。通过符号执行检查 P4 程序及表项快照，适合了解解析、反解析和转发属性的验证方法。

### INT 与遥测

- Changhoon Kim 等：[In-band Network Telemetry via Programmable Dataplanes](https://github.com/nkatta/nkatta.github.io/blob/37ee48e6e46818cfe6a8d3365a59e573c0d845c2/papers/int-demo.pdf)，*SIGCOMM 2015* 产业演示（作者稿）。以软件交换机为原型，展示用 P4 采集交换机内部状态、定位时延问题的早期 INT 方案。
- Shaofei Tang 等：[Sel-INT: A Runtime-Programmable Selective In-Band Network Telemetry System](https://doi.org/10.1109/TNSM.2019.2953327)，*IEEE Transactions on Network and Service Management*，17(2): 708–721，2020。研究遥测采样率与数据类型的运行时选择，原型基于 POF 和扩展的 Open vSwitch，适合比较不同的遥测设计。

INT 的报文格式、采集指令与报告机制可查阅 [p4-applications 的遥测规范目录](https://github.com/p4lang/p4-applications/tree/7eedb79d40e60ceb6d87f1a3682f75c28fc2b2ba/telemetry/specs)，引用或实现时写明所采用的文档及版本。

## C.4 代码仓库

### 编译、运行与拓扑

| 仓库                                                                  | 用途与使用条件                                                                   |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [p4lang/p4c](https://github.com/p4lang/p4c)                           | P4 编译器前端与多个目标后端。实际可用的后端取决于构建配置与依赖                  |
| [p4lang/behavioral-model](https://github.com/p4lang/behavioral-model) | BMv2 软件报文处理框架，包括 `simple_switch` 等目标，用于观察和验证报文处理行为   |
| [jafingerhut/p4-guide](https://github.com/jafingerhut/p4-guide)       | 安装说明、排错记录与示例。安装脚本的系统版本要求见其 `bin` 目录说明              |
| [nsg-ethz/p4-utils](https://github.com/nsg-ethz/p4-utils)             | 基于 Mininet 组织 P4 拓扑、启动交换机并操作控制接口，供 `p4-learning` 等项目使用 |

### 控制平面与测试

| 仓库                                                                                                             | 用途与使用条件                                                                   |
| ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [p4lang/p4runtime](https://github.com/p4lang/p4runtime)                                                          | P4Runtime 规范及 protobuf 接口定义。客户端绑定、协议版本和服务端能力需要配套核对 |
| [p4lang/p4runtime-shell](https://github.com/p4lang/p4runtime-shell)                                              | 交互式 P4Runtime 客户端，通过目标的 P4Runtime 服务读写表项和其他实体             |
| [opennetworkinglab/onos](https://github.com/opennetworkinglab/onos)                                              | 包含 P4Runtime 南向接口的 SDN 控制器，通过设备驱动和 pipeconf 对接具体流水线     |
| [p4lang/ptf](https://github.com/p4lang/ptf)                                                                      | Packet Test Framework，用于组织发包与期望报文检查。控制平面配置由测试程序安排    |
| [p4c 中的 P4Tools](https://github.com/p4lang/p4c/tree/8b6de3c579e717ee278c38041b868e9ef2345f5f/backends/p4tools) | 包括测试生成器 P4Testgen、随机程序生成器 P4Smith。需要相应构建选项及目标支持     |

### 研究应用

[p4lang/p4app-switchML](https://github.com/p4lang/p4app-switchML/tree/b5c74a04fa66faa82acab154a4e21c8f76d913f2) 提供 SwitchML 的交换机程序、控制器与端侧库，用网内聚合加速分布式训练中的 Allreduce。该版本采用 TNA，控制器使用 BF Runtime，主机侧库负责与训练框架及传输协议对接。适合研究网内聚合与端侧通信的配合。

## C.5 视频与课程资料

- [P4 Developer Days](https://p4.org/p4-developer-days/)：按日期整理的技术报告、录像和幻灯片，可按编译器、验证、遥测等主题查阅。
- [Stanford CS344 — Build an Internet Router](https://cs344-stanford.github.io/)：2020 年春季课程资料，包含 P4 数据平面与 Python 控制平面的路由器项目，实验平台为 NetFPGA 4 × 10GE，适合参考项目组织与接口分工。

看录像时同时打开对应代码或讲义，记录讲解采用的语言、架构和工具版本。

## C.6 中文资料

- [《用 P4 对数据平面进行编程》](https://yuba.stanford.edu/~nickm/papers/cccf.pdf)：Nick McKeown、Changhoon Kim 著，高荣新（Ron Kao）译，《中国计算机学会通讯》，2016 年 7 月。介绍数据平面可编程的背景与基本思路，适合入门阅读。具体语法应对照 P4<sub>16</sub> 规范。
- [附录 B · 术语表](B-术语表.md)：查阅本教程采用的中英术语，以及语言、架构、目标和控制接口的定义。

查阅中文博客或视频时，优先选择附有源码、版本说明和复现步骤的材料。检索代码标识符时保留英文原名，往往更容易找到规范条款和上游讨论。

## C.7 配套书籍

- Larry Peterson、Carmelo Cascone、Brian O’Connor、Thomas Vachuska、Bruce Davie：[Software-Defined Networks: A Systems Approach](https://github.com/SystemsApproach/SDN/tree/3f54123c4f225993d02816219d4102f18890231a)，开源版 v2.0。其中第 4 章讨论交换机及 P4，第 5 章通过 Stratum 介绍 P4Runtime，第 6、7 章通过 ONOS 和 SD-Fabric 介绍网络操作系统与叶脊交换网络。

## C.8 硬件与部署资料

从软件实验转向硬件时，可先阅读以下公开项目：

- [Open P4Studio](https://github.com/p4lang/open-p4studio)：提供 Tofino 模型、驱动、BF Runtime 接口及测试示例。模型运行与实机部署所需组件、公开获取条件及出处见 [16.4.3 节](../docs/16-PSA与TNA简介.md#1643-公开工具链与硬件部署)。
- [stratum/fabric-tna](https://github.com/stratum/fabric-tna/tree/fd3c3f0989ae6c2bb2384bdd1b5b7755168ba886)：SD-Fabric 的数据平面程序及 ONOS pipeconf、PTF 测试，涉及 TNA、Stratum 与 ONOS 的配合。仓库另含用于开发测试的 V1Model 版本。该版本的构建说明采用 SDE 9.7.0 和 ONOS 2.5.8 及以上版本。

选择具体设备时，先确认芯片型号、支持的架构、编译器版本、控制接口和 SDK 获取条件，以及用户可用的 P4 编译与部署接口。功能可先在软件模型中验证，再检查目标编译器的资源报告，并在实机上测量转发性能。

## C.9 会议与活动

| 入口                                                   | 可查阅的内容                                          |
| ------------------------------------------------------ | ----------------------------------------------------- |
| [ACM SIGCOMM 活动目录](https://www.sigcomm.org/events) | SIGCOMM、CoNEXT、HotNets 等会议与研讨会入口           |
| [USENIX 会议目录](https://www.usenix.org/conferences)  | NSDI 等会议。进入对应年份的页面查找论文、幻灯片和演讲 |
| [P4 活动目录](https://p4.org/events/)                  | P4 Workshop、EuroP4 等社区活动的具体安排              |

引用活动资料时注明年份、届次，以及论文、教程或演示等材料类型。

## C.10 如何提问与报告问题

先判断问题属于哪一层，再选择讨论渠道：

1. 语言理解、工具使用和实验设计问题，可先搜索 [P4 Forum](https://forum.p4.org/) 中的相关讨论。
2. 能稳定复现的工具缺陷，按项目指引报告到对应仓库，例如 [p4c Issues](https://github.com/p4lang/p4c/issues) 或 [BMv2 Issues](https://github.com/p4lang/behavioral-model/issues)。
3. 本教程的文字、示例或步骤问题，可提交到[本仓库 Issues](https://github.com/zhh2001/p4-language-guide-zh/issues)。

一份便于复现的问题说明通常需要：

- 预期行为与实际结果，包括输入报文和期望输出。
- 最小 P4 程序、表项配置，以及完整的编译和启动命令。
- 语言版本、架构、目标程序、工具版本或源码提交号。
- 涉及拓扑时的端口映射，涉及运行时问题时的相关日志和 PCAP。
- 已做过哪些检查，以及每一步得到的结果。

错误信息和命令尽量贴成文本，外部示例同时附上文件路径和提交号。

## 常用查阅入口

日常做实验时，可按问题查阅本附录：

1. [官方规范与参考](#c1-官方规范与参考)：核对语言语义、架构接口与控制协议。
2. [入门教程与练习](#c2-入门教程与练习)：选择后续练习。
3. [代码仓库](#c4-代码仓库)：查找编译器、目标程序、控制接口和测试工具。
4. [论文与阅读重点](#c3-论文与阅读重点)：了解设计思路与研究方法。
5. [如何提问与报告问题](#c10-如何提问与报告问题)：选择讨论渠道并整理复现材料。
