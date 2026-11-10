# 本地补丁说明（非上游内容）

本文件记录 2026-11-10 在本机对 SmoothFlow 5.0.4 Patch3 所做的**本地修改**。
这些改动**不在**上游 `SmoothFlow_5.0.4_Patch3_OPD2513_Candidate.zip` 内。
如果重新刷入上游 ZIP，本补丁会被覆盖，需要重新应用（见文末）。

## 修改文件

| 文件 | 原 md5 | 说明 |
|---|---|---|
| `bin/core.sh` | `b562d851fa8292542aa64ec4561c0abb` | 仅此文件被修改 |

原始文件备份：`/data/adb/smoothflow/code-backup-20261110-133657/core.sh.orig`

## 要解决的问题

上游 `set_val()` / `set_pct()` 的冲突判定是：

```sh
if [ "$_sv_cur" != "$_sv_last" ]; then   # 当前值 != 模块最后写入值
    log "检测到外部节点占用，跳过写入"
    return 0                              # 永久跳过
fi
```

厂商 `perf HAL`（`vendor.qti.hardware.perf2-hal-service`）会在模块写入后把节点改回原值
（实测开机阶段 8 秒内即被改回，见 `targetresourceconfigs.xml` 中 MajorValue=0x5 的资源表）。

一旦发生一次外部覆盖，`applied.txt` 里记录的"最后写入值"就永远对不上当前值，
该节点**永久失效**，且没有任何重新基线化的路径。

## 补丁内容

新增配置项 `CONFLICT_SETTLE_SECS`（默认 **120** 秒，`0` = 关闭，恢复上游行为）。

冲突发生时记录 `(路径, 当前值, 起始时间, 采纳次数)` 到 `conflict.state`：

```
/sys/.../policy0/walt/hispeed_load|90|1794289160|0
```

若当前值连续 `CONFLICT_SETTLE_SECS × (采纳次数 + 1)` 秒未被再次改写，则：

1. 有 `applied.txt` 记录的分支 → 把当前值写入 `applied.txt`（采纳为新归属）
2. 无记录但基线不一致的分支 → 用 `set_baseline()` 覆盖 `defaults.txt` 中的基线值

然后**继续执行原本的写入**，而不是跳过。采纳次数用于指数退避，避免与厂商高频互刷。

日志前缀为 `[自愈]`，例如：

```
[自愈] 外部占用已稳定 /sys/.../hispeed_load=90，采纳为新归属基线并重试写入
```

## 新增函数（位于 `bin/core.sh`）

- `conflict_rec_read` / `conflict_rec_write` / `conflict_forget` —— 冲突状态文件读写
- `set_baseline` —— 覆盖 `defaults.txt` 中已存在的基线值
- `conflict_should_adopt` —— 判断是否满足采纳条件（含指数退避）

## 行为差异

| 场景 | 上游行为 | 本补丁行为 |
|---|---|---|
| 首次检测到外部覆盖 | 永久跳过该节点 | 记录冲突，120 秒后采纳并重试 |
| 厂商反复改写 | 永久跳过 | 按 120s→240s→360s… 退避重试 |
| `CONFLICT_SETTLE_SECS=0` | — | 完全等同上游 |
| 无冲突时的正常写入 | 不变 | 不变 |

## 已知影响

- 守护进程在"漂移自愈暂停 10 分钟"期间不会调用写入函数，因此最坏情况下
  自愈要等这次暂停结束后才生效（约 10 分钟）。
- 采纳后 `defaults.txt` 中的基线会被更新为厂商当前值，卸载恢复时以该值为准。

## 自测结果

```
sh tests/selftest.sh  →  通过 87 项，失败 2 项
```

这 2 项失败（`锁属主身份判定`、`reap gate 恢复保护`）在**未打补丁的原始文件上同样失败**，
原因是测试会在根目录 `/` 下创建临时目录，而本机根文件系统为只读 erofs。
与本补丁无关。

## 回滚方法

```sh
sh /data/adb/modules/smoothflow/action.sh stop
cp /data/adb/smoothflow/code-backup-20261110-133657/core.sh.orig \
   /data/adb/modules/smoothflow/bin/core.sh
sh /data/adb/modules/smoothflow/action.sh start
```

或把 `CONFLICT_SETTLE_SECS=0` 写入 `/data/adb/smoothflow/config.sh` 以仅关闭自愈行为。

## 重新刷入上游后的恢复

1. 重新应用本补丁（保留本文件作为改动清单）
2. 删除 `conflict.state` 与 `state-backup-*` 之外的历史残留即可
