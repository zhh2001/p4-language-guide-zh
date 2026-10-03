# 附录 A · 核心库 `core.p4` 解析

> 本附录按接口解释核心库的声明，重点核对类型约束、长度单位、解析错误和默认动作。

语言语义以 P4_16 v1.2.5 为依据，接口与 p4c `1.2.5.10` 的 `p4include/core.p4` 核对。下文的接口声明用于阅读，包含核心库后不要再把它们重复写进程序。

## A.1 `core.p4` 是什么

`core.p4` 是 P4_16 核心库，以 P4 声明表达若干内建构造的接口。规范要求 P4 程序包含它，可以直接包含，也可以通过架构文件间接包含。本教程的完整示例通常显式写出：

```p4
#include <core.p4>
#include <v1model.p4>
```

本机的 `v1model.p4` 也包含 `core.p4`，核心库的 include guard 避免同一份文件被重复展开。这不允许程序再次声明已有的错误成员或 extern。

核心库包含标准错误、基本匹配种类、`packet_in`、`packet_out`、`verify`、`NoAction` 和 `static_assert`。计数器、计量器、寄存器、校验和对象、`mark_to_drop` 等接口来自架构库，不属于 `core.p4`。

读到一个 extern 声明时，还需要查其行为定义。仅凭方法签名，无法判断游标如何移动、错误发生后怎样转移，或目标是否支持某个调用。

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

这些成员属于 `error` 类型，使用时写成 `error.PacketTooShort`。程序可以通过另一个顶层 `error { ... }` 声明增加成员，但不能重复声明已有成员，也不能在成员声明中自行指定整数编码。

| 错误                    | 含义与边界                                                 |
| ----------------------- | ---------------------------------------------------------- |
| `NoError`               | 当前没有记录解析错误；协议约束仍需由程序显式检查           |
| `PacketTooShort`        | `extract`、`lookahead` 或 `advance` 所需数据超出输入报文   |
| `NoMatch`               | 按规范，Parser 的 `select` 没有匹配分支且没有兜底分支      |
| `StackOutOfBounds`      | Parser 访问报头栈的 `next`、`last` 等操作超出允许范围      |
| `HeaderTooShort`        | 可变长提取所需宽度超过目的报头声明的容量                   |
| `ParserTimeout`         | Parser 执行超过实现允许的时间限制；不是网络收包超时        |
| `ParserInvalidArgument` | 解析操作的参数不满足实现要求，例如目标要求按字节对齐的长度 |

`HeaderTooShort` 与 `PacketTooShort` 分别涉及目的报头容量和输入数据量，不能互换。多个条件同时违规时，不应依赖所有目标按同一顺序报告错误。

本教程的 p4c／BMv2 组合在 `select` 无匹配分支时存在实现差异，不能可靠地产生规范要求的 `NoMatch`。显式兜底的处理方法见 [6.4.1 节](../docs/06-Parser解析器.md#641-select-表达式)。普通报头栈下标的越界规则也不能一概归入 `StackOutOfBounds`：例如编译期已知的非法下标应在编译时被拒绝。

解析错误是否导致丢包由架构及后续处理决定。在 V1Model 中，Ingress 可以检查 `standard_metadata_t` 的 `parser_error` 字段，再明确执行丢弃逻辑。

## A.3 匹配种类 `match_kind`

```p4
match_kind {
    exact,
    ternary,
    lpm
}
```

| 名称      | 含义                                                     |
| --------- | -------------------------------------------------------- |
| `exact`   | 精确匹配键值                                             |
| `ternary` | 三态匹配，使用掩码表示每一位须匹配 0、须匹配 1，或不关心 |
| `lpm`     | 最长前缀匹配                                             |

`ternary` 与按源地址、目的地址、端口组成的“三元组”不是一个概念。表键直接使用 `exact` 等名字，不加 `match_kind.` 前缀。

规范只允许在架构描述中引入新的匹配种类，普通数据平面程序不能靠声明一个名字就为目标增加查表能力。架构可以提供 `range`、`optional` 等扩展；目标支持哪些类型及组合，还要检查编译器和运行时。表项重叠与优先级规则见[第 8 章](../docs/08-匹配动作表.md)。

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

`packet_in` 表示带读取游标的输入报文，由架构提供，用户不能自行实例化。Parser 接收这个对象并调用其方法；例如，`extract` 是只能在 Parser 中执行的特殊操作。能够在某处写出 extern 类型名，不意味着可以在那里任意调用其方法，具体调用还受语言与架构约束。

| 方法               | 类型与长度要求                                       | 成功后的效果                                           |
| ------------------ | ---------------------------------------------------- | ------------------------------------------------------ |
| `extract(h)`       | `h` 必须是定长 `header`，不是普通整数或任意 `struct` | 按字段顺序提取，使报头有效，游标前进报头所占位数       |
| `extract(h, bits)` | `h` 包含恰好一个 `varbit` 字段；`bits` 为 `bit<32>`  | 提取固定部分和指定长度的可变部分，使报头有效并前进游标 |
| `lookahead<T>()`   | `T` 为定长类型；返回值类型为 `T`                     | 查看当前位置的数据，不移动游标                         |
| `advance(bits)`    | `bits` 为 `bit<32>`，单位为位                        | 跳过这些位，不保存到报头                               |
| `length()`         | 返回 `bit<32>`，单位为字节                           | 返回输入报文总长度，不是当前位置的剩余长度             |

例如，Parser 依次执行以下语句，假设 `hdr.first` 和 `hdr.third` 都是只有一个 `bit<8> value` 字段的报头，`meta.peek` 为 `bit<8>`：

```p4
meta.peek = packet.lookahead<bit<8>>();
packet.extract(hdr.first);
packet.advance(32w8);
packet.extract(hdr.third);
```

若输入从 `A1 B2 C3 D4` 开始，则 `meta.peek` 与 `hdr.first.value` 都是 `0xA1`，`hdr.third.value` 为 `0xC3`，游标停在 `D4` 之前。这里没有消耗两次 `A1`；第二个字节由 `advance` 跳过。在支持 `length()` 的目标上，它仍应返回整个输入报文的字节数。

可变长提取的第二个参数只表示 **`varbit` 字段本身的位数**。例如目的报头含 `bit<16> kind` 和 `varbit<64> data`，调用 `extract(hdr.variable, 32w24)` 共消耗 `16 + 24 = 40` 位。位宽计算、容量检查和目标对齐约束见 [6.6 节](../docs/06-Parser解析器.md#66-extract-方法)。

`extract`、`lookahead`、`advance` 都可能因数据不足而结束当前解析路径。失败后不应继续使用未成功获得的字段。成功的 `lookahead` 若返回含报头的值，其中的报头为有效状态，但它仍不推进输入游标。

`length()` 并非所有目标都可实现。采用 cut-through 处理的设备可能在整包到齐前开始解析，尚无法知道总长度；此时目标可以在编译或加载阶段拒绝该调用。

**本机验证的限制**：p4c `1.2.5.10` 的前端接受 `packet.length()`，但 `p4c-bm2-ss` 后端报告 `packet.length(): not supported`。因此不能将它直接用于本机的 V1Model/BMv2 程序；需要读取包长时，应另行核对 V1Model 的 `standard_metadata.packet_length` 定义，见[第 11 章](../docs/11-V1Model架构.md)。

## A.5 输出对象 `packet_out`

```p4
extern packet_out {
    void emit<T>(in T hdr);
}
```

架构通常把 `packet_out` 传给执行反解析的控制块。P4_16 没有 `deparser` 关键字，具体控制块签名和调用位置由架构规定。

`emit` 将数据追加到输出报文，支持以下对象：

- `header`：有效时按字段声明顺序输出，无效时不输出；有效位本身不写入报文。
- 报头栈：按下标从小到大处理各元素，跳过无效报头。
- `header_union`：输出其中有效的成员。
- `struct`：按字段顺序递归处理报头或报头聚合字段。

不能直接输出普通 `bit<W>`、`bool`、枚举或 `error` 值，也不能把混有普通整数元数据的结构体整体当成报头集合输出。需要携带这些值时，应先按线路格式定义报头并填入字段。

连续两次 `emit` 同一个有效报头会追加两份内容；它不做去重，也不自动修正校验和。未解析负载如何接到输出后面，则由架构与目标定义。本教程的 BMv2 示例会保留并接上未解析负载，不能把这种整包处理规则仅归因于 `emit`。详见[第 9 章](../docs/09-Deparser反解析器.md)。

## A.6 空动作 `NoAction`

```p4
action NoAction() { }
```

`NoAction` 的动作体为空，不修改报头或元数据，不自行选择输出端口，也不自行丢包。原来已经设置的转发或丢弃状态不会被它清除。

一张表省略 `default_action` 时，规范要求编译器将默认动作补为 `NoAction`，并将它加入动作列表。这是表的默认动作规则，不表示每个未命中的表都执行 `NoAction`：如果程序显式指定了其他默认动作，就执行那个动作及其参数。

未命中而执行默认动作时，`apply().hit` 仍为 `false`；动作执行与表项命中是两件事。表的声明与返回值见[第 8 章](../docs/08-匹配动作表.md)。

## A.7 运行时检查 `verify`

```p4
extern void verify(in bool check, in error toSignal);
```

`verify` 是 Parser 专用的检查构造，调用形式与 extern 函数相似。本机 `core.p4` 包含这个声明；其特殊语义由语言规范规定。

条件为真时继续执行；为假时将解析错误设为第二个参数，立即转到 `reject`，当前状态内剩余语句不再执行。例如，先在顶层声明：

```p4
error { UnexpectedKind }
```

再在已经提取 `hdr.msg` 的 Parser 状态中检查：

```p4
verify(hdr.msg.kind == 8w1, error.UnexpectedKind);
```

检查失败不会回滚之前成功的报头提取或其他操作。因此，报头仍然有效也不能证明后续检查已通过。`reject` 是否导致丢包需要结合架构处理；V1Model 中的错误分流示例见 [6.7 节](../docs/06-Parser解析器.md#67-verify-与解析错误)。

## A.8 编译期检查 `static_assert`

```p4
extern bool static_assert(bool check, string message);
extern bool static_assert(bool check);
```

两个重载的参数均无方向修饰符，条件和消息必须在编译期已知。条件为真时返回 `true`；为假时编译失败，带消息的重载还会报告相应文字。它不生成逐包执行的检查。

包含核心库后，可以在顶层用返回值初始化常量：

```p4
const bit<32> SKIP_BITS = 8;
const bool SKIP_ALIGNED = static_assert(
    SKIP_BITS % 8 == 0, "SKIP_BITS must be byte-aligned");
```

将 `SKIP_BITS` 改为 7 会编译失败。这个断言只是程序作者给配置增加的约束，不表示所有目标都必须要求跳过长度按字节对齐。顶层不能直接放一条函数调用语句，因此这里需要常量声明。

报文字段的运行时值不能用作 `static_assert` 的条件。需要检查报文内容时使用 Parser 的 `verify` 或控制块逻辑。更完整的配置与布局检查见 [13.3 节](../docs/13-注解与高级特性.md#133-static_assert检查编译期条件)。

## A.9 核对本机使用的源文件

规范附录中的接口摘录与编译器随附文件可能在注释、include guard、注解等方面不同。例如，本机文件给 `NoAction` 加了 `@noWarn("unused")`，并包含上述 `verify` 声明。阅读时应固定版本，同时检查实际编译所用的文件。

在仓库根目录运行：

```bash
p4test --version
p4test --std p4-16 -M examples/01-hello/hello.p4
p4test --std p4-16 examples/01-hello/hello.p4
```

`-M` 输出预处理依赖，列出这个程序实际找到的 `core.p4` 与架构文件。本机核心库位于 `/usr/local/share/p4c/p4include/core.p4`；其他安装方式可能使用不同目录。最后一条命令执行语言与类型检查，不运行交换机，也不验证所有目标资源约束。

完整源码请查阅本机依赖路径，或本附录开头链接的固定版本。若通过 `-I` 或其他配置切换了包含路径，应重新核对依赖，避免读到的文件与编译时使用的文件不一致。

## A.10 接口核对要点

| 遇到的问题                 | 优先核对                                               |
| -------------------------- | ------------------------------------------------------ |
| 提取长度与预期不同         | `extract` 的固定部分、可变字段位数，以及位与字节的单位 |
| 解析失败后仍有输出         | 架构如何传递错误，后续控制块是否明确丢弃               |
| `emit` 报类型错误          | 参数是否只由可输出的报头及其聚合类型构成               |
| 表未命中却继续转发         | 默认动作及查表前已经写入的元数据                       |
| 编译器拒绝 `static_assert` | 条件是否在编译期已知，是否处于合法调用位置             |
| 文件里有声明但目标不能运行 | 编译器后端、目标能力和架构约束，而不只是接口是否存在   |

## A.11 相关章节

- `packet_in`、`extract`、`verify` → [第 6 章 · Parser](../docs/06-Parser解析器.md)
- `packet_out`、`emit` → [第 9 章 · Deparser](../docs/09-Deparser反解析器.md)
- `match_kind`、默认动作 → [第 8 章 · 匹配动作表](../docs/08-匹配动作表.md)
- `static_assert` → [第 13 章 · 注解与高级特性](../docs/13-注解与高级特性.md)
- 架构提供的接口与目标限制 → [第 10 章 · 架构与包](../docs/10-架构与包.md)
