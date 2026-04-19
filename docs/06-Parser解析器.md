# 06 · Parser 解析器

> 本章目标：把 P4 parser 这个"状态机"学透——声明、状态、`select`、`extract`、`verify`、`lookahead`、报头栈、子解析器。

## 6.1 Parser 是什么

Parser 负责把 **一串原始字节** 变成 **你定义的报头结构**：

```text
字节流 ──► [Parser 状态机] ──► headers 结构体
                                ├── ethernet (valid)
                                ├── ipv4     (valid)
                                └── tcp      (invalid)
```

它是一个 **有限状态机**。你从 `start` 出发，根据当前已提取字段的值跳转到不同状态，直到到达终态 `accept`（成功）或 `reject`（失败）。

## 6.2 Parser 的结构

```text
┌─────────────────────────────────────────┐
│  parser 声明                             │
│  ┌───────────────────────────────────┐  │
│  │ 局部常量/变量/对象实例            │  │
│  ├───────────────────────────────────┤  │
│  │ state start { ... }               │  │
│  │ state parse_ipv4 { ... }          │  │
│  │ state parse_tcp   { ... }         │  │
│  │ ...                                │  │
│  │ (accept 和 reject 是隐含存在的)   │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

- 必须有且仅有一个 `start` 状态
- `accept` 和 `reject` **不能显式声明**
- 状态名字不能重复，也不能与局部变量重名

## 6.3 声明语法

```p4
parser MyParser(packet_in              packet,
                out headers            hdr,
                inout metadata         meta,
                inout standard_metadata_t std_meta) {

    // 局部量（可选）
    Checksum16() ck;

    // 至少一个 state
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}
```

> [!WARNING]
> **parser 声明不能是泛型的**：
> ```p4
> parser P<H>(inout H data) { ... }   // ❌ 非法
> ```
> 但 **parser 类型** 声明可以泛型。架构里常见 `parser Parser<H>(...);` 这种类型声明，然后用户写非泛型的具体实现。

## 6.4 `transition` 语句

每个状态的最后一条语句可以是 `transition`。没写的话，隐含是 `transition reject;`。

```p4
state s_ok       { transition accept; }
state s_fail     { transition reject; }
state s_next     { transition parse_tcp; }  // 跳到另一个 state
```

### 6.4.1 `select` 表达式

通常根据已提取字段的值分发：

```p4
state start {
    packet.extract(hdr.ethernet);
    transition select(hdr.ethernet.etherType) {
        0x0800: parse_ipv4;
        0x86DD: parse_ipv6;
        0x0806: parse_arp;
        default: accept;
    }
}
```

右侧的标签是**集合**——下节详细讲。

### 6.4.2 多字段联合 select

用笛卡尔积：

```p4
transition select(hdr.ipv4.ihl, hdr.ipv4.protocol) {
    (4w0x5, 8w0x06): parse_tcp;
    (4w0x5, 8w0x11): parse_udp;
    (_,     _      ): accept;
}
```

## 6.5 标签集合的语法

### 6.5.1 单元素

```p4
4: continue;   // 仅匹配整数 4
```

### 6.5.2 全集

```p4
default: reject;
_:       reject;   // 同 default
```

### 6.5.3 掩码 `&&&`

右侧是掩码，**掩码位为 0 的位可以是任何值**：

```p4
8w0x0A &&& 8w0x0F   // XXXX1010，16 种取值
```

**应用例：判断 TCP 保留端口（< 1024）**

```p4
select (p.tcp.port) {
    16w0 &&& 16w0xFC00: well_known_port;  // 最高 6 位为 0
    _: other_port;
}
```

### 6.5.4 区间 `..`

闭区间，两端都包含：

```p4
4s5 .. 4s8   // { 5, 6, 7, 8 }
```

第二个值 < 第一个值 → 空集。

## 6.6 `extract` 方法

P4 核心库中 `packet_in` 的定义：

```p4
extern packet_in {
    void extract<T>(out T headerLvalue);
    void extract<T>(out T variableSizeHeader, in bit<32> variableFieldSize);
    T    lookahead<T>();
    bit<32> length();
    void advance(bit<32> bits);
}
```

### 6.6.1 固定宽度 `extract(hdr)`

最常见形式：把当前"读指针"后面的字节塞进 header 并把有效位置 true：

```p4
state start {
    packet.extract(hdr.ethernet);
    transition accept;
}
```

等价伪代码：

```text
1. 需要 sizeof(Ethernet_h) 字节
2. 若剩余字节不够 → reject，parserError = PacketTooShort
3. 拷贝字节到 hdr.ethernet，从最高有效位开始
4. hdr.ethernet.setValid()
5. nextBitIndex += sizeof(Ethernet_h)
```

### 6.6.2 可变宽度 `extract(hdr, bits)`

当 header 里有一个 `varbit<W>` 字段时用：

```p4
header IPv4_no_options_h { /* 固定 20 字节 */ }
header IPv4_options_h    { varbit<320> options; }

state parse_ipv4 {
    packet.extract(hdr.ipv4);
    verify(hdr.ipv4.ihl >= 5, error.InvalidIPv4Header);
    transition select(hdr.ipv4.ihl) {
        5: dispatch_on_protocol;        // 无 options
        _: parse_ipv4_options;
    }
}

state parse_ipv4_options {
    // options 字段长度 = (ihl - 5) * 32 bits
    packet.extract(hdr.ipv4opt,
                   (bit<32>)(((bit<16>)hdr.ipv4.ihl - 5) * 32));
    transition dispatch_on_protocol;
}
```

> [!TIP]
> **`ihl` 字段**
> `ihl` = Internet Header Length，单位 32 位字。最小 5（= 20 字节，不带 options）。

## 6.7 `verify` 语句

用于 **在解析阶段做前置校验**：

```p4
extern void verify(in bool condition, in error err);
```

条件为 false 时：

1. 立刻跳转到 `reject`
2. 把 `err` 赋给 `standard_metadata.parser_error`（V1Model）或架构特定的错误字段

典型用法：

```p4
verify(hdr.ipv4.version == 4, error.IPv4BadVersion);
verify(hdr.ipv4.ihl     >= 5, error.InvalidIPv4Header);
```

> [!TIP]
> `verify` **只能在 parser 里用**。Control 块里要检查错误，用 `if` + `drop`。

## 6.8 `lookahead`

"偷看"接下来的若干位，但 **不移动读指针**：

```p4
T result = packet.lookahead<T>();
```

`T` 必须是 **固定宽度** 的类型。当剩余字节不够时同样会 reject。

**应用例：解析 TCP options**

TCP options 每项第一个字节是 kind，根据 kind 决定如何提取后续字节。必须先"偷看"这一字节才能决定跳到哪个状态：

```p4
state start {
    transition select(packet.lookahead<bit<8>>()) {
        8w0x0: parse_tcp_option_end;
        8w0x1: parse_tcp_option_nop;
        8w0x2: parse_tcp_option_mss;
        // ...
    }
}
```

## 6.9 `advance` 与跳过

### 方式一：明确知道要跳多少位

```p4
packet.advance(64);    // 跳过 64 位
```

伪代码：

```text
if (nextBitIndex + bits > lengthInBits) reject, PacketTooShort
nextBitIndex += bits
```

### 方式二：提取到 `_`

按类型 T 消耗对应位数但 **不保存**：

```p4
packet.extract<bit<32>>(_);
```

## 6.10 报头栈解析

报头栈的 `next` 和 `last` 只在 parser 中可用。典型例子：MPLS 栈解析，按 BOS（Bottom-of-Stack）位决定是否继续：

```p4
header Ethernet_h { /* ... */ }
header Mpls_h {
    bit<20> label;
    bit<3>  tc;
    bit<1>  bos;
    bit<8>  ttl;
}

struct headers {
    Ethernet_h ethernet;
    Mpls_h[3]  mpls;
    // ...
}

parser P(packet_in b, out headers hdr, ...) {
    state start {
        b.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x8847: parse_mpls;
            0x0800: parse_ipv4;
        }
    }
    state parse_mpls {
        b.extract(hdr.mpls.next);                 // 栈顶+1
        transition select(hdr.mpls.last.bos) {    // 看刚 extract 的这层
            0: parse_mpls;   // 不是栈底，继续下一层
            1: parse_ipv4;   // 是栈底，后面就是 IPv4
        }
    }
    state parse_ipv4 { /* ... */ }
}
```

> [!WARNING]
> **栈大小 = 硬编码的最大深度**。上例 `Mpls_h[3]` 意味着最多解析 3 层 MPLS——第 4 层会触发 `StackOutOfBounds` 错误。**P4 parser 不能无限循环**，硬件必须静态知道上界。

## 6.11 子解析器（Sub-parser）

一个 parser 可以调用另一个 parser 的 `apply` 方法：

```p4
parser Inner(packet_in p, out IPv4_h ipv4) { /* ... */ }

parser Outer(packet_in p, out headers hdr) {
    Inner() inner;    // 实例化

    state start {
        p.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: call_inner;
            default: accept;
        }
    }

    state call_inner {
        inner.apply(p, hdr.ipv4);   // 调用子解析器
        transition accept;
    }
}
```

**子解析器的控制流**：

- 子的 `accept` → 返回到调用点继续执行
- 子的 `reject` → 父也立刻 reject
- **不能递归**（间接递归也不行）

## 6.12 Parser 里的局部变量与实例

解析器状态之前可以有：

- **常量** `const`
- **局部变量**（作用域：整个 parser）
- **extern 对象的实例化**（例如 Checksum16）

```p4
parser P(packet_in b, out Parsed_packet p) {
    Checksum16() ck;     // 实例化一个校验和计算器

    state start {
        b.extract(p.ethernet);
        // ...
    }
    state parse_ipv4 {
        b.extract(p.ip);
        ck.clear();
        ck.update(p.ip);
        verify(ck.get() == 16w0, error.IPv4ChecksumError);
        transition accept;
    }
}
```

**注意**：状态名和局部变量名共享命名空间，不能重复。

## 6.13 Parser 不允许做的事

| 操作 | 原因 |
| ---- | ---- |
| 递归状态机 | 硬件必须静态展开 |
| 调用 table.apply | 表属于 control，不属于 parser |
| `return` / `exit` | parser 只能通过 `transition` 终止 |
| 数学运算状态控制 | 过于复杂，无法静态分析 |

## 6.14 完整示例：解析 Ethernet + VLAN + IPv4

```p4
#include <core.p4>
#include <v1model.p4>

header ethernet_t {
    bit<48> dst;
    bit<48> src;
    bit<16> etherType;
}

header vlan_t {
    bit<3>  pcp;
    bit<1>  dei;
    bit<12> vid;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> id;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> src;
    bit<32> dst;
}

struct headers {
    ethernet_t ethernet;
    vlan_t     vlan;
    ipv4_t     ipv4;
}

struct metadata { }

parser MyParser(packet_in p,
                out headers hdr,
                inout metadata m,
                inout standard_metadata_t s) {

    state start { transition parse_eth; }

    state parse_eth {
        p.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x8100: parse_vlan;
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_vlan {
        p.extract(hdr.vlan);
        transition select(hdr.vlan.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        p.extract(hdr.ipv4);
        verify(hdr.ipv4.version == 4, error.IPv4IncorrectVersion);
        transition accept;
    }
}
```

## 6.15 本章小结

- Parser 是一个 **状态机**，由 `start` 到 `accept`/`reject`
- `extract` 提取固定或可变宽度报头，并自动 `setValid()`
- `verify` 做前置校验，失败即 reject
- `select` + 集合（单值 / 掩码 / 区间 / `default`）做分发
- `lookahead` 偷看数据但不消耗
- 报头栈用 `next`/`last`/`lastIndex` 自动推进
- **不可递归**、**不可 `return`**、**不可调用表**

## 6.16 下一步

Parser 把报头拆出来之后，就该进入 **真正做决策的地方** 了——[07 · 控制块与动作](./07-控制块与动作.md)。
