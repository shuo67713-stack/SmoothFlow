# SmoothFlow 5.0.6-rc3 构建与测试报告

- 基线：5.0.6-rc2。调度参数与 rc2 逐值一致，本轮不调参（游戏档 hispeed_load 78、down_rate_limit_us 10000 仍待真机 A/B）。
- 本轮内容：统一会话生命周期（reinit_session / sf_start / sf_stop / sf_reinit）；KernelSU Next 临时注入 Root 的手动启停（action.sh start|stop|reinit）；每次启动重读原始参数（遗留未恢复记录先恢复再清空，恢复不完整拒绝启动）；service.sh 改调 sf_start；自测 $DATA→$DATADIR 修复（第 30、33 节）；自测新增第 34–38 节。
- Shell 语法检查：全部脚本通过。
- 隔离自测：95 项通过、0 失败——root 与非 root（nobody，即 CI 条件）各一轮；另从构建 ZIP 解包后以非 root 复跑，同样 95/95（第 37 节为此对齐了拉起进程所用的测试模式 core）。
- 锁压力测试：非 root 身份，40 轮双进程场景通过。
- 手动控制端到端（沙箱夹具 + 真实进程）：action.sh start 拉起 supervisor/daemon（PID 文件齐全）；reinit 后基线重新采集（defaults 16 条）；stop 后 stopped=1、状态文件清空、无残留进程。
- 发布包构建：成功；发布版 bin/core.sh 的 SF_* 残留检查由 package.sh fail-closed 门禁执行（残留 0）。产物 SmoothFlow_5.0.6-rc3_OPD2513.zip，SHA-256 见同名 .sha256。
- 系统分区：运行时脚本静态守卫（自测第 38 节）确认无 boot/init_boot/system 等分区写入目标；模块只写 sysfs/procfs 运行时节点与 /data/adb/smoothflow。
- 设备侧：本候选版的生命周期变更尚未在 OPD2513 实机回归；按冒烟清单重点过手动启停、停止恢复与卸载恢复后再转正式版。
- 结论：可作为 5.0.6-rc3 候选交付；不宣称性能/续航/温度提升。
