# 示例 04 · 基于 5-tuple 的 ACL

> 目标：展示 **ternary 表** 和 **direct_counter** 的典型用法，实现一个能精细拒绝/放行流量的 ACL。

对应教程：[docs/08-匹配动作表.md](../../docs/08-匹配动作表.md)、[docs/12-外部对象Extern.md](../../docs/12-外部对象Extern.md)。

## 拓扑

```text
  h1 ── port 1 ─┐
                │  s1 (acl.p4)
  h2 ── port 2 ─┤
                │
  h3 ── port 3 ─┘
```

## ACL 策略（示例）

控制平面下发的示例规则（`runtime/s1-commands.txt`）：

| 优先级 | 源 IP | 目的 IP | 协议 | dst port | 动作 |
| ------ | ----- | ------- | ---- | -------- | ---- |
| 高 | 10.0.0.1 | 10.0.0.3 | * | * | **deny** |
| 中 | * | 10.0.0.0/24 | TCP | 22 | **deny**（禁 SSH） |
| 低 | * | * | * | * | **permit** |

## 编译 + 运行

```bash
./build.sh
sudo ./run.sh
```

预期：

- `h1 ping h3` 被高优先级规则拒掉
- `h1 ssh h2`（port 22）被中优先级规则拒掉
- 其他流量正常

## 读计数器

```bash
simple_switch_CLI --thrift-port 9090 <<EOF
table_dump MyIngress.acl
counter_read MyIngress.acl_ctr 0
counter_read MyIngress.acl_ctr 1
EOF
```

能看到每条 ACL 规则命中的 packets 和 bytes。

## 关键知识点

- `ternary` key：每个字段都可以是 `value &&& mask`，或 `_` 表示全匹配
- 多字段 ternary 必须用 **priority**（`largest_priority_wins = true` 时值越大越先匹配）
- `direct_counter` 自动绑定每一条表项，无需手动管理 index
- `switch (acl.apply().action_run)` 根据实际执行的动作分支

## 练习

- 把 `default_action` 改成 `deny`，再明确 permit；这是真实部署更常见的"白名单"策略
- 加上对 TCP flags 的匹配：允许已建立连接的返回流（`ACK=1`）
- 把 ACL 改成 "状态化"：用 `register` 记录已建立连接的 5-tuple，流入新连接要经过更严格检查
