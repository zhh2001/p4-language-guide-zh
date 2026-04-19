# 示例 01 · Hello P4

> 目标：跑通最简单的 P4 程序——每个报文从进来的端口原路发回。用来验证环境 + 建立流水线直觉。

对应教程：[docs/03-第一个P4程序.md](../../docs/03-第一个P4程序.md)。

## 拓扑

```text
  h1 ── port 1 ── s1 ── port 2 ── h2
               (hello.p4)
```

## 预期效果

- `h1 ping h2` **不通**（因为包从 h1 进入 s1 就被打回 h1）
- `h1 tcpdump -i h1-eth0` 能看到 **自己发出去的 ICMP Request 又被收回来**

## 编译

```bash
./build.sh
```

产物：

- `hello.json` —— 给 BMv2 加载
- `hello.p4info.txt` —— 给 P4Runtime 用（此示例用不到）

## 运行

```bash
sudo ./run.sh
```

脚本会创建 veth 对、启动 BMv2、跑几个 ping 做验证，最后清理现场。

如果你已经有 Mininet 偏好，直接读源码改造即可。
