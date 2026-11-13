## v5.0.6-rc7 — Review follow-ups: stale-check ordering, restore logging, stop_daemon identity retention

- 基线：rc6 源码；依据 rc6 独立审查合并报告（2026-11-13，七路审查，合并评级有条件通过 B+）的定点清单，由 ChatGPT 官网产出补丁（构建方仅修正其两处 hunk 行数标注）、构建方落地并独立验证。不改调度参数、不放宽任何门禁。
- R2 对齐：`lock_owner_stale` 把 Z|X 状态判定移到 starttime 非空/数字校验之前，与 `reap_gate_owner_stale` 一致——僵尸进程 + 损坏 starttime 的锁可正常回收；构建报告此前「僵尸不受此限」的过宽表述随之与代码一致。
- R1/R3 硬化：三处隔离副本还原分支（reap_gate_stale、recover_stale_reap_gate、recover_unproven_reap_gate）在跳过还原、还原失败或还原后 inode 复验不一致时写入日志并注明隔离路径，不再静默；协议判定与返回值不变。
- stop_daemon 身份保留：原 PID 存活但 starttime 非数字、且锁记录缺失时，将原始 PID 纳入既有失败校验，避免兜底替换为空后误删 PID 文件并误报停止成功。
- 测试：§51 新增拒绝原因日志证据断言（条件项）；§55 扩展为六格矩阵（活/死/僵尸 × 记录形态，覆盖严格 gate 与 lock gate 两条路径），死 PID 改为动态获取；新增 §56 发布守卫负向测试。判别验证：rc7 测试对 rc6 源码恰好失败 §55 僵尸格，对 rc5 源码恰好失败 §54b/§55/§56。
- 全套自测 root 与非 root 通过（116 项，个别轮次 115 项为 §51 条件断言未触发）；锁压力测试通过。

## v5.0.6-rc6 — Post-review fixes: reap-gate recheck (M1-A), starttime validation (M1-B), publish guards

- 基线：rc5 源码；依据 ChatGPT 官网总审（2026-11-13，评级不通过 B−）中经构建方逐项对源码核实成立的条目定点修复，不重写、不删既有安全机制、不改调度参数。
- M1-A：`recover_unproven_reap_gate` 在隔离改名后只复核 inode，未复查属主记录，与严格证明路径不对称——末次检查与改名之间若迟到的属主刚发布记录，隔离副本会被误删。本版补齐改名后复查：隔离副本的 pid 记录内容变化、或出现可解析属主记录时，一律改名还原并返回失败，绝不删除。
- M1-B：`reap_gate_owner_stale` 与 `lock_owner_stale` 对记录中的 starttime 只验非空、不验数字，「活 PID + 非数字 starttime」会被字符串不等误判为属主已死，与函数头注的 fail-closed 承诺矛盾。本版在 PID 存活需比对 starttime 时先验数字，非数字即记录损坏、不判陈旧（PID 已不存在/僵尸时死亡由缺席证明，与 starttime 无关）。`gate_has_owner_record` 的宽松口径有意保留：它决定的是「有命名属主则保留」的 fail-closed 分流。
- 发布守卫补齐：`lock_profile`、`acquire_supervisor_lock`、`reap_lock_dir` 三处在发布属主记录前未验自身 starttime 可读（舰队核查最初报两处，构建方复查源码确认共三处；daemon/session 两锁 rc5 前已有此守卫）。读不到 starttime 时拒绝发布残缺的「PID + 空」记录。
- 测试补强：§51 并发启停断言由「返回码全是数字」改为实测语义（stop 恒 0、双 start 至多一个以 1 干净失败、终态自洽；探针三轮实测分布 000/000/010）；新增 §54（观察窗内与改名后出现迟到属主记录的确定性注入）、§55（非数字 starttime 记录矩阵）；自测夹具 `run()` 为子进程在假 /proc 中建模自身 stat 条目，以满足发布守卫的身份读取（需要真实身份语义的条目仍在块内改用真 /proc）。原有断言未删未弱化；全套 114 项在 root 与非 root 下均通过。
- 文档口径修正：构建报告交付清单改按交付目录实物表述（源码包与其 .sha256 为并列交付文件，不再声称位于源码包内部 dist/）；BUILD.md 删除「尚未核对 5.0.5 正式源码差异」的过时表述（三方对照已于 2026-11-12 完成）；COOLAPK_POST.md 由 5.0.4 草稿刷新为本版。
- CPU 调度参数与 rc5 逐项一致；不增加 GPU、温控或系统分区写入；不宣称性能、温度、功耗或续航改善。

## v5.0.6-rc5 — Audit fixes: unproven reap-gate recovery (M1) and unlock identity (A4)

- 基线：rc4 源码；依据《SmoothFlow_5.0.6-rc4_独立审计报告》定点修复，不重写、不删既有安全机制、不改调度参数。
- M1：`recover_stale_reap_gate` 在严格 PID+starttime 证明失败时分流——有命名属主的 gate 仍 fail-closed 保留；仅无属主记录（pid 记录缺失/为空/不可解析）的陈旧 gate 走新增 `recover_unproven_reap_gate` 时限协议：年龄 >30 秒（与 `lock_owner_stale` 无记录规则一致）、双重观察 inode/mtime/记录内容不变、原子改名隔离并复核 inode 后才删除。此前此类 gate 会导致启动永久拒绝。
- A4：`unlock_profile` 恢复 5.0.5 的 PID+starttime 整行双校验（逐字一致），记录缺失/损坏/不匹配时安全失败。
- 新增自测第 48–53 节（真实故障注入）：无主 gate 时限恢复与新鲜 gate 保留、gate 记录矩阵（损坏/仅 PID/PID 复用/活属主）、unlock 身份矩阵、并发 start/start/stop 状态自洽、uninstall 失败中止与成功归档、gate 创建后发布 pid 前强杀进程的端到端启动。原有 104 项断言未改、未弱化；全套 111 项在 root 与非 root 下均通过。
- P2 一致性：action.sh 面板遗留 rc2 文案、NOTICE 遗留 rc1 描述已修正；版本号统一 v5.0.6-rc5 / versionCode 510；构建报告交付清单与实物逐项对齐（本版起源码包实物随包附于 dist 并附 .sha256）。
- CPU 调度参数与 rc4 逐项一致；不增加 GPU、温控或系统分区写入；不宣称性能、温度、功耗或续航改善。

## v5.0.6-rc4 — Lifecycle transaction and watchdog regression fixes

- 基线：rc3 源码；逐项对照 GitHub `v5.0.5` 恢复 daemon 原子单实例锁、Supervisor 指数退避/熔断、启动阶段 stale `.reap` gate 安全恢复。
- 新增独立 session 生命周期锁，串行化 service/action 的 start、stop、reinit；`reinit` 在同一把锁内完成停止、恢复与重新启动。
- 启动事务失败即中止：快照采集失败不写节点；初始档位应用失败按归属记录回滚；Supervisor 未确认启动时先停止守护，再尝试恢复，恢复失败保留快照。
- stop 检查停止标记、状态文件清理及读回结果；PID 文件缺失/过期时回退锁目录 PID+starttime，身份不明仍 fail-closed；任何关键步骤失败均返回非零。
- 卸载改为调用统一 `sf_stop`，避免卸载与手动 start/stop 并发；检查数据归档失败。
- 增加退避状态机、daemon/session 锁、stale reap gate 恢复测试；锁压力测试覆盖 profile/supervisor/daemon/session 四类锁。
- CPU 调度参数与 rc3 保持不变；不增加 GPU、温控或系统分区写入；不宣称性能、温度、功耗或续航改善。

# 更新记录

## v5.0.6-rc3 — Lifecycle hardening for manual start/stop

- 基线：5.0.6-rc2；调度参数与 rc2 完全一致（游戏档 hispeed_load 78、down_rate_limit_us 10000），本轮不调参。
- 新增统一会话生命周期（core.sh：reinit_session / sf_start / sf_stop / sf_reinit）：开机启动与手动启动共用同一路径。
- 适配 KernelSU Next 临时注入 Root：action.sh 新增 start / stop / reinit 手动控制，不依赖开机脚本；停止在 Root 在场时同步完成恢复。
- 每次启动重新初始化：上个会话遗留的未恢复记录先按其快照恢复，随后清空状态，原始参数一律从当前节点重新读取，不沿用旧快照作基线；遗留恢复不完整时拒绝启动（fail-closed）。
- service.sh 改为调用 sf_start，删除与 core 重复的启停逻辑。
- 修复自测第 30、33 节在非 root 环境下夹具变量 $DATA 未导出导致路径塌陷的问题（$DATA → $DATADIR）；自测在 root 与非 root（CI）环境均可通过。
- 自测新增第 34–38 节：停止恢复、脏会话重新初始化、幂等停止、手动启停全周期（真实 supervisor/daemon）、系统分区写入静态守卫。
- 保证不写入 boot、init_boot、system 等系统分区：运行时脚本静态守卫已纳入自测；模块只写 sysfs/procfs 运行时节点与自身数据目录。

## v5.0.6-rc2 — Conservative CPU response tuning

- 基线：5.0.6-rc1（Patch3 ReviewFix + R1/R2/R4 收尾）；不是 5.0.5 正式源码的替代品。
- 游戏档 `hispeed_load`：低/高 CPU policy 均由 80 调整为 78，负载达到阈值时稍早触发 hispeed。
- 游戏档 `down_rate_limit_us`：由 8000 调整为 10000，略微延长降频间隔，尝试减少短周期频率来回切换。该改动可能增加高负载持续时间与功耗，需实机 A/B 验证。
- 游戏档 hispeed/rtg 频率目标、CPU scaling_min/max、uclamp、日常档和省电档参数全部保持 rc1 原值。
- 不修改 GPU、温控、在线核心数或系统分区；不宣称 FPS、帧时间、温度或续航已提升。
- 本版本是可回滚的实验候选，不是正式发布版。

## v5.0.6-rc2 — Candidate stabilization

- 基线：SmoothFlow 5.0.4 Patch3 ReviewFix；不是 5.0.5 正式源码的替代品。
- 修复 reap gate 回收直接删除公共路径的问题：改为唯一隔离路径原子改名，并校验目录 inode 后清理。
- 发布打包增加 fail-closed 检查，任何 SF_* 测试环境覆盖残留都会阻断构建。
- 增加活跃 reap gate 的 fail-closed 单元测试与双进程压力测试场景。
- 保持既有 CPU 调度参数、游戏规则、守护节拍和 sysfs 写入范围不变；本候选版不宣称实机性能提升。
- 与 5.0.5 的差异尚未核对：本候选版直接从 5.0.4 Patch3 ReviewFix 分支演进，不能视为包含 5.0.5 的全部变更。

## v5.0.4 — Open Source Preparation

- 作者署名统一为 `硕`，整理 GitHub / 酷安发布材料。
- 修复 uclamp 比较只检查整数部分的问题：`10.50` 不再被误判为 `10.00`。
- 漂移检测采用完整百分比比较，避免漏报小数差异。
- daemon 正常退出、停止标记退出或收到终止信号时，按 PID 与启动时间双重校验清理自身 PID 文件。
- 状态面板对 uclamp 零值的判断使用同一规范化规则。
- 新增 uclamp 小数写入、原值恢复和漂移检测回归用例。
- 增加 GPL-3.0 License、AI 辅助开发说明、贡献指南、安全策略、行为准则和 GitHub Actions 测试流程。
- 默认调度参数、游戏规则、10 秒守护节拍不作性能性调整。
- 不增加 GPU、温控、分区写入；不宣称真实设备 FPS、帧时间或功耗提升。

## v5.0.3 — Safety Maintenance

- 在 5.0.2 安全维护基础上增加受管节点目标值格式校验，格式异常或白名单外路径拒绝写入。
- 加强 supervisor 单实例锁，降低 service 与手动 start 并发启动多个守护进程的风险。
- 状态文件写入/读回失败时明确写日志。
- `check` 区分策略关键项偏差和全部已登记节点的归属冲突。
- 保持默认 WALT / uclamp 调度值与守护节拍不变。

## v5.0.2 — Safety Hardened

- 将基线采集延后到系统启动完成和目标节点就绪后，并为每次实际写入增加单节点基线门禁。
- 写入前校验白名单、节点读写状态和原始快照；基线和归属记录采用临时文件、原子替换和读回校验。
- 恢复记录失败时按所有权条件尝试回滚。
- 将可选 WALT `up_rate_limit_us` 纳入快照，并补齐游戏档退出 / 省电切换恢复。
- 移除状态面板固定字段读取中的 `eval`。

## v5.0.1

- 修复启动等待日志计算并恢复 ZIP 内脚本权限布局。

## v5.0.0

- 基于 4.2.0 的安全维护和诊断状态说明版本。
