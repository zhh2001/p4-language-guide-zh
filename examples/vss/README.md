# VSS · Very Simple Switch 架构参考

本目录依据 P4<sub>16</sub> 语言规范 **1.2.5 第 5 节**整理，用于阅读架构接口与完整程序的装配方式。VSS 是规范中的教学架构，第 5.1 节给出 P4 接口，第 5.2 节说明固定功能模块的行为，第 5.3 节给出 IPv4 转发程序。规范版本入口见[附录 C](../../appendix/C-学习资源.md#c1-官方规范与参考)。

本地阅读版沿用规范示例的四张表和处理顺序，调整动作列表语法，并加入头文件包含保护、临时下一跳初始化和显式的路由丢弃分支。架构与 Package 的基础知识见[第 10 章](../../docs/10-架构与包.md)。

## 文件与架构边界

| 文件                                                         | 内容                                                                               |
| ------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| [very_simple_switch_model.p4](./very_simple_switch_model.p4) | 端口类型、输入输出元数据、Parser/Control 接口、`VSS` 包和 `Checksum16` extern 声明 |
| [vss.p4](./vss.p4)                                           | Ethernet/IPv4 报头、解析器、四张匹配动作表、Deparser 与 `main` 实例                |

架构文件声明可编程块和 extern 的接口，程序文件提供 Parser、流水线与 Deparser 的实现。支持 VSS 的目标负责端口收发、输入仲裁、Parser 错误传递、输出分发、负载拼接及 `Checksum16` 方法的执行。

本仓库为 VSS 提供 `p4test` 语言层检查，未提供运行目标。需要在本机运行 IPv4 转发实验时，可使用基于 V1Model 与 BMv2 `simple_switch` 的[示例 03](../03-ipv4-router/README.md)。

## 接口与端口

```text
TopParser → TopPipe → TopDeparser
               │
               └─ outCtrl.outputPort → VSS 固定功能输出分发
```

`TopParser` 输出 `Parsed_packet`。架构将这些报头、解析错误和 `InControl` 交给 `TopPipe`，后者修改报头并填写 `OutControl`。`TopDeparser` 发出修改后的报头，输出分发模块将其与 Parser 留下的负载拼接。`VSS(TopParser(), TopPipe(), TopDeparser()) main` 绑定三个实现，其参数类型和方向须符合架构声明。

`PortId` 为 `bit<4>`，规范为 VSS 定义了以下端口用途：

| 数值        | 用途               |
| ----------- | ------------------ |
| 0~7         | 物理 Ethernet 端口 |
| 13（`0xD`） | 重循环输入/输出    |
| 14（`0xE`） | CPU 输入/输出      |
| 15（`0xF`） | 丢弃输出           |

8~12 属于无效输出端口，VSS 要求丢弃发往这些端口的报文。输入仲裁模块填写 `inCtrl.inputPort`，记录物理、重循环或 CPU 输入端口，`TopPipe` 则通过 `outCtrl.outputPort` 选择输出。这些端口值由 VSS 定义，V1Model 的端口与元数据见[第 11 章](../../docs/11-V1Model架构.md)。

输出选择 `CPU_OUT_PORT` 时，VSS 将**原始输入报文**交给控制平面，并丢弃 Deparser 生成的报文。例如，`TopPipe` 将 TTL 从 1 减到 0 后选择 CPU 输出，CPU 收到的原始报文中 TTL 仍为 1。选择 `RECIRCULATE_OUT_PORT` 时，重新组装的输出报文经重循环通道返回输入侧。这两条路径的收发行为由 VSS 固定功能模块规定。

## 解析与校验和

Parser 先提取 Ethernet 报头，仅在 EtherType 为 `0x0800` 时继续解析 IPv4。`select` 没有默认分支，其余 EtherType 会进入 `reject`，并产生 `error.NoMatch`。IPv4 解析检查版本为 4、IHL 为 5，再验证报头校验和。提取所需字节不足时会产生 `error.PacketTooShort`。这些错误由架构传入 `parseError`，`TopPipe` 随后设置丢弃端口并返回。

`Checksum16` 由 VSS 架构声明。Parser 和 Deparser 各自实例化一个独立的 `ck`，方法职责如下：

| 方法           | 用途                                         |
| -------------- | -------------------------------------------- |
| `clear()`      | 开始一次新的计算                             |
| `update(data)` | 按字段声明顺序加入待计算的数据               |
| `remove(data)` | 从当前校验和状态中移除数据贡献，本例没有调用 |
| `get()`        | 取得 16 位反码校验和                         |

验证输入时，`ck.update(p.ip)` 包含报文原有的 `hdrChecksum` 字段。按 VSS 定义的反码校验和语义，有效 IPv4 报头的 `ck.get()` 应为 0。此处比较的是整个报头的计算结果，报文携带的校验和字段值由报头内容决定。

生成输出时，程序先把 `hdrChecksum` 置 0，再将整个 IPv4 报头加入计算，最后写回结果。清零使原有校验和不再参与新值的计算。V1Model 常见写法从计算元组中排除该字段，调用时应按各自 API 确定参与计算的数据。

## 四张表与配置前提

| 执行顺序 | 表           | 匹配键              | 主要动作                     |
| -------- | ------------ | ------------------- | ---------------------------- |
| 1        | `ipv4_match` | 目的 IPv4，LPM      | 设置下一跳和出端口，TTL 减 1 |
| 2        | `check_ttl`  | 递减后的 TTL，exact | 将选定报文送到 CPU           |
| 3        | `dmac`       | 下一跳 IPv4，exact  | 设置目的 MAC                 |
| 4        | `smac`       | 输出端口，exact     | 设置源 MAC                   |

路由表执行 `Drop_action` 时，本地版本根据 `action_run` 直接返回。执行 `Set_nhop` 后，程序继续检查输出端口和 TTL 表，未选择丢弃或 CPU 输出时再查询 `dmac`。`dmac` 执行后仍未丢弃，才查询 `smac`。`nextHop` 初始化为 0，实际转发使用的是 `Set_nhop` 写入的下一跳。

源码声明表和默认动作，普通表项由控制平面下发。路由表和两张 MAC 表的初始默认动作都是 `Drop_action`，这些默认动作未声明为 `const`，可由控制平面修改。要完成正常转发，需要配置目的前缀、下一跳、物理出端口和两侧 MAC。

`check_ttl` 的 `const default_action` 固定为 `NoAction`。要实现规范描述的超时路径，控制平面需配置 **`0 → Send_to_cpu`**。下面按该表项已安装、路由及 MAC 表齐备的条件分析控制流：

| 输入 TTL | 执行 `Set_nhop` 后 | 后续处理                                    |
| -------- | ------------------ | ------------------------------------------- |
| 64       | 63                 | TTL 表未命中，继续查询 MAC 表               |
| 1        | 0                  | TTL 表命中，选择 CPU 输出，CPU 接收原始报文 |
| 0        | 255                | 8 位无符号减法回绕，不能被 TTL=0 表项识别   |

扩展本例的 TTL 处理时，应在递减前处理 TTL 为 0 的输入，并明确丢弃或送 CPU 的策略。`Send_to_cpu` 只选择输出端口，ICMP Time Exceeded 由控制平面后续生成。若未安装上述 TTL 表项且路由选择物理端口，输入 TTL 为 1 的报文会在减到 0 后继续查询 MAC 表。

## 本地检查

从**仓库根目录**执行，无需 sudo：

```bash
p4test --version
p4test --std p4-16 examples/vss/vss.p4
```

本机 `p4test` 会执行解析、类型检查及编译器前中端处理，可以检查动作列表、参数方向和包实例装配。成功时退出码为 0，`--toJSON` 可导出编译器 IR。IR JSON 用于查看编译后的程序结构，BMv2 所需的目标配置则由相应后端生成。报文转发与 `Checksum16` 方法的运行行为需由 VSS 目标验证。

本机检查返回 0，报告四个未使用的架构常量：`REAL_PORT_COUNT`、`RECIRCULATE_IN_PORT`、`CPU_IN_PORT`、`RECIRCULATE_OUT_PORT`。

本机通过独立命令 `p4test` 调用上述检查，`p4c` 驱动未注册名为 `p4test` 的目标。`p4c-bm2-ss` 按 V1Model 编译时要求 `V1Switch` 顶层包，本例的 `VSS` 会得到包类型不匹配的诊断。移植到 V1Model 时，需要按其接口重新组织可编程块、元数据和 extern 调用。

## 阅读与扩展

当前 Parser 未检查 IPv4 `totalLen` 与实际输入长度的关系，传输层报头作为未解析负载保留。

- 对照[第 10 章](../../docs/10-架构与包.md)，区分 P4 接口声明与规范对固定功能模块的文字约定。
- 对照[示例 03](../03-ipv4-router/README.md)，分析如何在 V1Model 中传递解析错误、选择输出端口和更新校验和。
- 扩展 TTL 处理，分别记录正常转发、TTL 0 和 TTL 1 的控制流，以及 CPU 收到的报文内容。

实测工具：p4c/p4test `1.2.5.10`。本地验证包括静态检查、IR 导出和目标接口诊断，以上报文处理行为依据规范与源码分析。
