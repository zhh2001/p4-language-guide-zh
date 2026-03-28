# P4 Guide (Chinese) | P4语言中文教程

> A comprehensive Chinese tutorial for the P4 programming language (P4_16)

教程入口：[`/P4.md`](/P4.md)

---

## 📘 项目简介

本项目是一个系统性的 **P4（P4_16）语言中文教程**，面向：

* SDN / 网络方向研究生
* 数据平面编程工程师
* P4 初学者 & 进阶用户

内容覆盖：

* ✅ P4语言基础（语法 + 类型系统）
* ✅ Parser（协议解析）
* ✅ Match-Action Pipeline（核心）
* ✅ Control Flow（控制逻辑）
* ✅ Deparser（报文重组）
* ✅ Architecture（V1Model / PSA）
* ✅ BMv2 实验
* ✅ P4Runtime 控制平面

---

## 🚀 为什么学习 P4？

P4 是一种用于 **数据平面编程（Data Plane Programming）** 的领域特定语言，可用于：

* 可编程交换机
* 智能网卡（NIC）
* 软件交换机（BMv2）

相比传统网络设备：

* ✔ 协议无关（Protocol-independent）
* ✔ 可编程转发逻辑
* ✔ 灵活实现新协议 / 新功能

---

## 🧠 教程结构

```text
Packet Processing Pipeline:

Packet
  ↓
Parser
  ↓
Match-Action Pipeline
  ↓
Control Flow
  ↓
Deparser
  ↓
Output
```

---

## 🧪 示例代码

所有示例代码位于：

```txt
examples/
```

包含：

* 基础 parser
* L2 switch
* IPv4 router
* ACL
* Load balancing

---

## 🛠️ 环境

推荐：

* BMv2 (simple_switch)
* P4C compiler
* Mininet（可选）

---

## 🤝 贡献

欢迎：

* 提交 PR
* 修正错误
* 增加案例

---

## 📜 License

MIT License

---

## ⭐ Star History

后续会继续完善，跟上最新的官方版本，如果这个项目对你有帮助，欢迎点个 ⭐
