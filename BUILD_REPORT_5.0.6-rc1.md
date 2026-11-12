# SmoothFlow 5.0.6-rc1 构建与核验记录

## 基线

- 本候选版以 `SmoothFlow 5.0.4 Patch3 ReviewFix` 为代码基线。
- 用户补充的 Patch2 源码用于差异追溯；Patch2 → Patch3 ReviewFix 的变更文件为 `bin/core.sh`、`bin/supervisor.sh`、`scripts/package.sh`、`tests/lock_stress.sh`、`tests/selftest.sh`，另增加 Patch3 修复说明。
- 未提供 5.0.5 正式源码或可核验提交，因此不能确认本候选版包含 5.0.5 的全部改动，也不能宣称与 5.0.5 等价。

## 本轮修改

1. R1：`reap_gate_stale()` 不再直接删除公共 gate 路径；改为先绑定目录设备号/inode 与 owner 记录，判定后再次核对，再原子改名到本进程专属隔离路径，移动后再次核验身份再清理。异常身份不匹配时尽可能恢复原路径并 fail-closed。
2. R2：发布构建完成 SF_* 测试环境覆盖剥离后，增加 fail-closed grep 断言；任何测试覆盖标记残留都会使构建失败。
3. R4：新增活跃 reap gate 单元测试；锁压力测试新增活 PID gate 不可回收断言。
4. 版本标识改为 `v5.0.6-rc1` / `versionCode=506`，并增加基线差异说明。

## 验证结果

- Shell 语法检查：通过。
- 隔离自测：88 项通过，0 项失败（源码树与构建 ZIP 均通过）。
- 锁压力测试：源码树和构建 ZIP 各执行 5 轮；每轮覆盖 profile 与 supervisor 两类锁，共 10 个双进程锁竞争轮次/构建位置，通过。
- 发布包检查：ZIP 根目录包含模块入口；发布版 `bin/core.sh` 不含 `SF_TEST_MODE`、`SF_SYS`、`SF_PROC`、`SF_CG`、`SF_DATADIR`、`SF_TRASH`、`SF_GETPROP` 覆盖入口。
- SHA-256：构建包校验通过。

## 未完成 / 不可声称

- 未在 OnePlus Pad 3 Pro / Android 16 / KernelSU 或 SukiSU Ultra 真机执行安装、启动、停止、模式切换、卸载恢复测试。
- 未对 5.0.5 正式源码做逐文件比较。
- 本轮没有修改 CPU 调度频率目标、WALT/uclamp 参数、游戏识别规则、daemon 10 秒节拍、GPU 或温控策略。因此这是安全与可靠性候选更新，不是已验证的 CPU 性能/功耗优化版本；没有 FPS、帧时间、温度或续航提升证据。
