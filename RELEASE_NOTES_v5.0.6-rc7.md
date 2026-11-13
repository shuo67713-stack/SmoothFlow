# SmoothFlow v5.0.6-rc7 发布说明（候选版，未发布）

基线：v5.0.6-rc6。依据 rc6 独立审查合并报告（2026-11-13，合并评级有条件通过 B+）的 rc7 定点清单，由 ChatGPT 官网（项目「SmoothFlow 审查」）产出补丁、构建方落地并独立验证。CPU 调度参数与 rc6 逐项一致；不新增 GPU/温控操作；不写系统分区。

## 本版变更（仅 bin/core.sh 与 tests/selftest.sh）

1. **lock_owner_stale 判定顺序对齐（R2）**：/proc 存在性检查之后，先判 Z|X 僵尸/退出状态，再验 starttime 非空/数字——与 reap_gate_owner_stale 一致。僵尸进程 + 损坏 starttime 的锁现在可正常回收；其余语义不变。
2. **隔离副本还原留痕（R1/R3 硬化，不改协议）**：reap_gate_stale、recover_stale_reap_gate、recover_unproven_reap_gate 三处还原分支：因原路径被重建而跳过还原、还原失败、或还原后 inode 复验不一致时，均写入模块日志（含隔离副本完整路径），不再静默。判定逻辑与返回值语义未变；未使用非可移植参数。
3. **stop_daemon 身份保留**：PIDF/SUPIDF 原记录为「存活 PID + 非数字 starttime」且对应锁记录缺失时，原始 PID 纳入既有 _sd_failed 校验路径——不再被兜底替换为空后误删 PID 文件并误报停止成功（ChatGPT 复核确认原校验循环不能覆盖此情形，并给出故障注入实测：stop_daemon 返回 1、PID 文件保留）。
4. **§51 证据断言**：并发启停出现单个 start 返回 1 时，额外断言模块日志含门禁拒绝行（「遗留回收门禁未能安全恢复，拒绝启动」或「生命周期操作正在执行」），把构建方的 8 轮日志取证结论变成常驻断言。
5. **§55 矩阵扩充**：新增「活 PID + 错误数字 starttime → 保留」「活 PID + 正确 starttime → 保留」「僵尸 PID + 非数字 starttime → 可回收（严格 gate 与 lock gate 两条路径）」；死 PID 改为动态获取（短命子进程 wait 回收），不再硬编码 424242。
6. **§56 发布守卫负向测试（新增）**：自身 stat 不可读时，lock_profile、acquire_supervisor_lock、reap_lock_dir 三者必须拒绝发布、清理空目录、不遗留 pid 文件。

## 验证摘要

- 隔离自测：nobody 身份 116/116 与 115/115 各一次、root 116/116（§51 证据断言为条件项，仅在该轮出现单个 start 返回 1 时计数，故总数在 115/116 间浮动）；锁压力测试通过。
- 判别验证：rc7 测试对 rc6 源码恰好失败 §55 的僵尸-lock 格（证明 R2 修复有判别测试）；对 rc5 源码恰好失败 §54b、§55、§56 三项（证明三组新测试均真实有效）。
- 本版未在 OPD2513 真机安装/回归；不宣称帧率、帧时间、温度、功耗或续航改善。rc7 未发布、未刷机。
