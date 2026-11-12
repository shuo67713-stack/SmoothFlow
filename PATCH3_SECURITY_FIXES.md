# SmoothFlow 5.0.4 Patch3 安全修复记录

本修复包基于 `SmoothFlow_5.0.4 + Patch2`，针对《第四轮安全审计报告》执行增量修复。模块版本号保持 v5.0.4，不冒用已发布版本号；本文件中的 Patch3 表示本次源码修复批次。

## 修复内容

- A：回收等待者检查 `.reap` 门的 PID/starttime；仅在确认 owner 已退出、PID 已复用，或无 PID 门超过 30 秒兜底时回收。活 owner 仍 fail-closed。
- B：锁 owner 处于 Z/X 状态时判定为失效。
- C：SIGKILL 升级前再次执行 PID、角色、启动时间校验。Shell 无法提供 pidfd 式原子校验与发信号，残余 TOCTOU 风险仍存在。
- D：supervisor 记录 daemon 子 PID；收到 HUP/INT/TERM 时置停止标志、向子进程转发 TERM 并 wait 后清理自身锁。
- F：运行时发布 core 固定真实路径与 getprop，不再接受 SF_* 环境覆盖；隔离测试专用 core 单独放在 tests/core.sh，运行时入口不引用。
- G：打包改为逐文件 allowlist，避免目录递归复制杂散文件。
- H：新增真实 pid_is_ours 测试，覆盖正确身份、启动时间不符、cmdline 不符。
- I：锁压力测试新增空锁目录、无 PID 孤儿 gate、有陈旧 PID 孤儿 gate 场景，并加入 worker 超时保护。
- 信息级：归档失败写入日志；增加 restore_all 直接调用测试。

## 验证

- `sh -n`：所有修改的 Shell 脚本语法检查通过。
- `tests/selftest.sh`：87 项通过，0 项失败。
- `tests/lock_stress.sh`：20 轮 × 2 类锁（40 轮双 worker），通过；另覆盖空锁和两类孤儿 gate。
- 发布 ZIP 已构建并生成 SHA-256。

## 未完成的设备侧验证

本轮未在 OnePlus Pad 3 Pro / Android / KernelSU 实机执行生命周期与调度回归，也未执行完整 Android 沙箱测试。C 的 PID 信号竞态无法由 Shell 完全消除。安装前应保留原包和恢复路径；不要把本轮主机测试等同于实机验证。
