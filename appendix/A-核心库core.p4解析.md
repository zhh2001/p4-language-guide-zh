# 附录 A · 核心库 `core.p4` 解析

> 本附录把 `core.p4` 逐节拆开，讲清楚每个声明的来历。**任何 P4 程序都必然包含这个文件**——懂它，就能看懂所有 P4 源码开头那几行。

## A.1 `core.p4` 是什么

`core.p4` 由 P4.org 随语言规范发布，包含：

- 必需的 error 定义
- 必需的 match_kind
- `packet_in` / `packet_out` extern（报文读写器）
- `NoAction`（默认空动作）
- `verify()`（parser 前置校验）
- `static_assert` 等编译期工具

**它不包含任何架构特定的 extern**——counter / meter / register 都是各架构自己的。

## A.2 开头

```p4
error {
    NoError,
    PacketTooShort,
    NoMatch,
    StackOutOfBounds,
    HeaderTooShort,
    ParserTimeout,
    ParserInvalidArgument
}
```

**这些是所有 P4 程序共享的错误常量**。`error` 命名空间是全局的——用 `error.PacketTooShort` 访问。

常用的：

- `PacketTooShort`：`extract` 时字节不够
- `StackOutOfBounds`：访问报头栈越界（`next` 越界）
- `HeaderTooShort`：`varbit` 长度超过上限

## A.3 Match Kind

```p4
match_kind {
    exact,
    ternary,
    lpm
}
```

最基础的三种匹配：精确、三元组、最长前缀。详见 [08 章](../docs/08-匹配动作表.md)。

> [!WARNING]
> 新的 `match_kind` **只能在架构描述文件里声明**。普通程序不行。

## A.4 `packet_in`

```p4
extern packet_in {
    void extract<T>(out T headerLvalue);
    void extract<T>(out T variableSizeHeader, in bit<32> variableFieldSize);
    T    lookahead<T>();
    bit<32> length();
    void advance(bit<32> bits);
}
```

报文读取器，**只能在 parser 中出现**。

| 方法 | 作用 |
| ---- | ---- |
| `extract(h)` | 提取固定长度 header，自动 setValid |
| `extract(h, bits)` | 提取 varbit 字段，显式指定位数 |
| `lookahead<T>()` | 偷看接下来 `sizeof(T)` 位，不消耗 |
| `length()` | 返回输入字节数（部分目标不支持） |
| `advance(n)` | 跳过 n 位 |

## A.5 `packet_out`

```p4
extern packet_out {
    void emit<T>(in T data);
}
```

报文写出器，只用在 Deparser。`emit` 自动跳过 invalid header；详见 [09 章](../docs/09-Deparser反解析器.md)。

## A.6 `NoAction`

```p4
action NoAction() { }
```

空动作，默认值时编译器会插它。

## A.7 `verify`

```p4
extern void verify(in bool condition, in error err);
```

parser 专用前置校验。见 [06.7](../docs/06-Parser解析器.md)。

## A.8 Static Assertion

```p4
extern bool static_assert(bool check, string message);
extern bool static_assert(bool check);
```

编译期断言，不产生运行时开销。

## A.9 完整 `core.p4` 源文件

以下是 P4_16 规范里最新的 core.p4（做了少量注释，实际位于 `p4c` 源码的 `p4include/core.p4`）：

```p4
/// 标准错误常量
error {
    NoError,
    PacketTooShort,
    NoMatch,
    StackOutOfBounds,
    HeaderTooShort,
    ParserTimeout,
    ParserInvalidArgument
}

/// 基本匹配方式
match_kind {
    exact,
    ternary,
    lpm
}

/// 报文输入
extern packet_in {
    void extract<T>(out T headerLvalue);
    void extract<T>(out T variableSizeHeader, in bit<32> variableFieldSize);
    T    lookahead<T>();
    bit<32> length();
    void advance(in bit<32> bits);
}

/// 报文输出
extern packet_out {
    void emit<T>(in T data);
}

/// 默认动作
action NoAction() { }

/// parser 校验
extern void verify(in bool check, in error toSignal);

/// 编译期断言
extern bool static_assert(bool check, string message);
extern bool static_assert(bool check);
```

## A.10 读 core.p4 的收益

- **看懂所有 P4 程序的开头**
- 知道哪些 error 是预定义的（不要重复声明）
- 知道 `extract`/`emit` 的精确语义
- 了解 `NoAction` 为什么无处不在

## A.11 相关章节

- `packet_in`、`extract`、`verify` → [06 章 Parser](../docs/06-Parser解析器.md)
- `packet_out`、`emit` → [09 章 Deparser](../docs/09-Deparser反解析器.md)
- `match_kind` → [08 章 Table](../docs/08-匹配动作表.md)
- `static_assert` → [13 章 高级特性](../docs/13-注解与高级特性.md)
