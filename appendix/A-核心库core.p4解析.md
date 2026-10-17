# 附录 A · 核心库 `core.p4` 解析

本附录按接口解释核心库的声明，说明类型约束、长度单位、解析错误和默认动作。

语言语义以 P4₁₆ v1.2.5 为依据，接口与 p4c `1.2.5.10` 的 [`core.p4`](https://github.com/p4lang/p4c/blob/8b6de3c579e717ee278c38041b868e9ef2345f5f/p4include/core.p4)核对。下文声明为接口摘录，完整程序通过包含核心库使用这些接口。

## A.1 `core.p4` 是什么

`core.p4` 是 P4₁₆ 核心库，以 P4 声明表达若干内建构造的接口。规范要求 P4 程序包含它，可以直接包含，也可以通过架构文件间接包含。本教程的完整示例通常显式写出：

```p4
#include <core.p4>
#include <v1model.p4>
```

本机的 `v1model.p4` 也包含 `core.p4`，核心库的 include guard 避免同一份文件被重复展开。

核心库包含标准错误、基本匹配种类、`packet_in`、`packet_out`、`verify`、`NoAction` 和 `static_assert`。计数器、计量器、寄存器、校验和对象、`mark_to_drop` 等接口由架构库提供。

接口声明用于核对参数和返回类型，游标移动、解析状态转移等行为由规范定义，具体支持范围由目标实现决定。

## A.2 标准错误

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

这些成员属于 `error` 类型，使用时写成 `error.PacketTooShort`。程序可以通过另一个顶层 `error { ... }` 声明增加名称唯一的新成员，整数编码由实现安排。

| 错误                    | 含义与边界                                                 |
| ----------------------- | ---------------------------------------------------------- |
| `NoError`               | 当前解析路径没有记录错误，协议约束由程序显式检查           |
| `PacketTooShort`        | `extract`、`lookahead` 或 `advance` 所需数据超出输入报文   |
| `NoMatch`               | 按规范，Parser 的 `select` 没有匹配分支且没有兜底分支      |
| `StackOutOfBounds`      | Parser 访问报头栈的 `next`、`last` 等操作超出允许范围      |
| `HeaderTooShort`        | 可变长提取所需宽度超过目的报头声明的容量                   |
| `ParserTimeout`         | Parser 执行超过目标允许的时间限制                          |
| `ParserInvalidArgument` | 解析操作的参数不满足实现要求，例如目标要求按字节对齐的长度 |

定位变长提取错误时，应分别检查目的报头容量和输入报文的剩余数据量，对应 `HeaderTooShort` 与 `PacketTooShort`。

本教程的 p4c/BMv2 组合在 `select` 没有匹配分支且没有兜底分支时会结束解析，但 `parser_error` 仍为 `NoError`。需要记录 `NoMatch` 时，可按 [6.4.1 节](../docs/06-Parser解析器.md#641-select-表达式)显式添加兜底检查。普通报头栈下标另有规则，编译期已知的非法下标会在编译时被拒绝。

解析错误是否导致丢包由架构及后续处理决定。在 V1Model 中，Ingress 可以检查 `standard_metadata_t` 的 `parser_error` 字段，再明确执行丢弃逻辑。

## A.3 匹配种类 `match_kind`

```p4
match_kind {
    exact,
    ternary,
    lpm
}
```

| 名称      | 含义                                                                 |
| --------- | -------------------------------------------------------------------- |
| `exact`   | 精确匹配键值                                                         |
| `ternary` | 三元匹配，也称三态匹配，用掩码表示每一位须匹配 0、须匹配 1，或不关心 |
| `lpm`     | 最长前缀匹配                                                         |

表键直接使用 `exact`、`ternary`、`lpm` 等名字。

新增匹配种类的声明限于架构描述，`range`、`optional` 等扩展及其可用组合由架构、编译器和运行时共同支持。表项重叠与优先级规则见[第 8 章](../docs/08-匹配动作表.md)。

## A.4 输入对象 `packet_in`

```p4
extern packet_in {
    void extract<T>(out T hdr);
    void extract<T>(out T variableSizeHeader,
                    in bit<32> variableFieldSizeInBits);
    T lookahead<T>();
    void advance(in bit<32> sizeInBits);
    bit<32> length();
}
```

`packet_in` 由架构提供，用户不能自行实例化。Parser 通过它读取带游标的输入报文，`extract` 的调用限于 Parser。

| 方法               | 类型与长度要求                                      | 成功后的效果                                           |
| ------------------ | --------------------------------------------------- | ------------------------------------------------------ |
| `extract(h)`       | `h` 必须是定长 `header`                             | 按字段顺序提取，使报头有效，游标前进报头所占位数       |
| `extract(h, bits)` | `h` 包含恰好一个 `varbit` 字段，`bits` 为 `bit<32>` | 提取固定部分和指定长度的可变部分，使报头有效并前进游标 |
| `lookahead<T>()`   | `T` 为定长类型，返回值类型为 `T`                    | 查看当前位置的数据，不移动游标                         |
| `advance(bits)`    | `bits` 为 `bit<32>`，单位为位                       | 跳过这些位，不保存到报头                               |
| `length()`         | 返回 `bit<32>`，单位为字节                          | 返回输入报文总长度                                     |

例如，Parser 依次执行以下语句，假设 `hdr.first` 和 `hdr.third` 都是只有一个 `bit<8> value` 字段的报头，`meta.peek` 为 `bit<8>`：

```p4
meta.peek = packet.lookahead<bit<8>>();
packet.extract(hdr.first);
packet.advance(32w8);
packet.extract(hdr.third);
```

若输入从 `A1 B2 C3 D4` 开始，则 `meta.peek` 与 `hdr.first.value` 都是 `0xA1`，`hdr.third.value` 为 `0xC3`，游标停在 `D4` 之前。`lookahead` 只观察 `A1`，第一次 `extract` 消耗 `A1`，`advance` 跳过 `B2`。在支持 `length()` 的目标上，它仍返回整个输入报文的字节数。

可变长提取的第二个参数只表示 **`varbit` 字段本身的位数**。例如目的报头含 `bit<16> kind` 和 `varbit<64> data`，调用 `extract(hdr.variable, 32w24)` 共消耗 `16 + 24 = 40` 位。位宽计算、容量检查和目标对齐约束见 [6.6 节](../docs/06-Parser解析器.md#66-extract-方法)。

`extract`、`lookahead`、`advance` 因数据不足而失败时，会记录 `PacketTooShort` 并转到 `reject`。成功的 `lookahead` 若返回含报头的值，其中的报头为有效状态，输入游标保持不变。

`length()` 需要目标能提供整个输入报文的长度。采用 cut-through 处理的设备若在整包到齐前开始解析，可以在编译或加载阶段拒绝该调用。

本机 p4c `1.2.5.10` 的前端接受 `packet.length()`，`p4c-bm2-ss` 后端则报告 `packet.length(): not supported`。本机 V1Model 程序可读取 `standard_metadata.packet_length`，字段定义见[第 11 章](../docs/11-V1Model架构.md)。

## A.5 输出对象 `packet_out`

```p4
extern packet_out {
    void emit<T>(in T hdr);
}
```

架构通常把 `packet_out` 传给执行反解析的控制块。反解析控制块的签名和调用位置由架构规定，P4₁₆ 没有单独的 `deparser` 关键字。

`emit` 将数据追加到输出报文，支持以下对象：

- `header`：有效时按字段声明顺序输出，无效时跳过，有效位本身不占线路字节。
- 报头栈：按下标从小到大处理各元素，跳过无效报头。
- `header_union`：输出其中有效的成员。
- `struct`：按字段顺序递归处理报头或报头聚合字段。

`emit` 的参数由报头及其聚合类型构成。普通 `bit<W>`、`bool`、枚举或 `error` 等元数据值需要先按线路格式装入报头字段，再随报头输出。

每次 `emit` 都追加一次序列化结果，连续输出同一个有效报头会得到两份内容。校验和更新由程序另行安排，未解析负载的衔接由架构与目标定义。本教程的 BMv2 示例会保留并接上未解析负载，详见[第 9 章](../docs/09-Deparser反解析器.md)。

## A.6 空动作 `NoAction`

```p4
action NoAction() { }
```

`NoAction` 的动作体为空，执行后报头、元数据以及已经设置的转发或丢弃状态保持原样。

表省略 `default_action` 时，编译器将默认动作补为 `NoAction`，并将它加入动作列表。显式指定其他默认动作时，未命中便执行所指定的动作及其参数。

未命中而执行默认动作时，`apply().hit` 仍为 `false`。表的声明与返回值见[第 8 章](../docs/08-匹配动作表.md)。

## A.7 运行时检查 `verify`

```p4
extern void verify(in bool check, in error toSignal);
```

`verify` 由核心库声明，执行语义由语言规范定义，调用限于 Parser。

条件为真时继续执行，为假时将解析错误设为第二个参数，立即转到 `reject`，当前状态内剩余语句不再执行。例如，先在顶层声明：

```p4
error { UnexpectedKind }
```

再在已经提取 `hdr.msg` 的 Parser 状态中检查：

```p4
verify(hdr.msg.kind == 8w1, error.UnexpectedKind);
```

检查失败时，之前成功提取的报头仍然有效，已完成的操作保留。V1Model 在 Ingress 中读取 `parser_error`，据此决定是否丢弃报文，错误分流示例见 [6.7 节](../docs/06-Parser解析器.md#67-verify-与解析错误)。

## A.8 编译期检查 `static_assert`

```p4
extern bool static_assert(bool check, string message);
extern bool static_assert(bool check);
```

两个重载的参数均无方向修饰符，条件和消息必须在编译期已知。条件为真时返回 `true`，为假时编译失败，带消息的重载还会报告相应文字。

包含核心库后，可以在顶层通过常量声明使用返回值：

```p4
const int SKIP_BITS = 8;
const bool SKIP_ALIGNED = static_assert(
    SKIP_BITS % 8 == 0, "SKIP_BITS must be byte-aligned");
```

这里用 `int` 常量做编译期取余，与 [4.6 节](../docs/04-语法基础.md#46-运算符速查)的运算类型一致。断言为 `SKIP_BITS` 设置了 8 位对齐约束，改为 7 就会使编译失败。

运行时的报文内容检查使用 Parser 的 `verify` 或控制块逻辑。更完整的配置与布局检查见 [13.3 节](../docs/13-注解与高级特性.md#133-static_assert检查编译期条件)。

## A.9 核对本机使用的源文件

规范附录中的接口摘录与编译器随附文件可能在注释、include guard、注解等方面不同。例如，本机文件给 `NoAction` 加了 `@noWarn("unused")`，并包含上述 `verify` 声明。阅读时应固定版本，同时检查实际编译所用的文件。

在仓库根目录运行：

```bash
p4test --version
p4test --std p4-16 -M examples/01-hello/hello.p4
p4test --std p4-16 examples/01-hello/hello.p4
```

`-M` 输出预处理依赖，列出这个程序实际找到的 `core.p4` 与架构文件。本机核心库位于 `/usr/local/share/p4c/p4include/core.p4`，实际目录取决于安装方式。最后一条命令执行语言与类型检查。

完整源码可从依赖输出的路径或本附录开头链接的固定版本查阅。通过 `-I` 等配置调整包含路径后，再用 `-M` 核对实际使用的文件。

## A.10 接口核对要点

| 遇到的问题                 | 优先核对                                               |
| -------------------------- | ------------------------------------------------------ |
| 提取长度与预期不同         | `extract` 的固定部分、可变字段位数，以及位与字节的单位 |
| 解析失败后仍有输出         | 架构如何传递错误，后续控制块是否明确丢弃               |
| `emit` 报类型错误          | 参数是否只由可输出的报头及其聚合类型构成               |
| 表未命中却继续转发         | 默认动作及查表前已经写入的元数据                       |
| 编译器拒绝 `static_assert` | 条件是否在编译期已知，是否处于合法调用位置             |
| 文件里有声明但目标不能运行 | 编译器后端的支持范围、目标能力和架构调用约束           |

## A.11 相关章节

- `packet_in`、`extract`、`verify` → [第 6 章 · Parser](../docs/06-Parser解析器.md)
- `packet_out`、`emit` → [第 9 章 · Deparser](../docs/09-Deparser反解析器.md)
- `match_kind`、默认动作 → [第 8 章 · 匹配动作表](../docs/08-匹配动作表.md)
- `static_assert` → [第 13 章 · 注解与高级特性](../docs/13-注解与高级特性.md)
- 架构提供的接口与目标限制 → [第 10 章 · 架构与包](../docs/10-架构与包.md)
