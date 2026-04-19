# 示例 VSS · Very Simple Switch（官方参考）

> 这是 P4_16 官方规范附录里的完整参考示例。**不是** 基于 V1Model，**是** 基于规范自带的 VSS 架构。学术/规范阅读时用得到。

## 为什么收录

- 规范作者当作"语言完整性示例"写的，覆盖面广（解析、校验和、表、Deparser）
- 展示了 **非 V1Model 架构** 的代码长啥样——对理解架构模型有好处
- 用 `Checksum16()` 的手动 API，和 V1Model 的 `verify_checksum/update_checksum` 风格差异明显

## 文件

- `very_simple_switch_model.p4` —— VSS **架构描述** 文件（声明接口、extern、顶层 package）
- `vss.p4` —— 用户程序：经典的"以 dst IP 转发 + MAC 改写 + TTL - 1"

## 运行

**不能在 BMv2 上直接跑**——VSS 没有对应的软件目标。这两个文件主要用于：

- 阅读、理解规范
- 语法检查：`p4c --target p4test vss.p4`

## 学完建议

读完 [docs/10-架构与包.md](../../docs/10-架构与包.md) 再回来看，体会"同一份语言、不同架构"的感觉。
