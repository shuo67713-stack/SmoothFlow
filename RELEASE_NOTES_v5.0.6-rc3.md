# SmoothFlow v5.0.6-rc3（候选版）

## 基线与兼容性声明

本候选版基于 `SmoothFlow 5.0.6-rc2`。CPU 调度参数与 rc2 完全一致（游戏档 hispeed_load 78、down_rate_limit_us 10000），本轮不调参，rc2 的参数 A/B 结论仍待真机验证。本线仍未与 5.0.5 正式源码逐文件核对。

## 本轮变更

- 统一会话生命周期：core.sh 新增 reinit_session / sf_start / sf_stop / sf_reinit，开机启动（service.sh）与手动启动共用同一路径，service.sh 删除重复的启停逻辑。
- KernelSU Next 临时注入 Root 适配：action.sh 新增 `start` / `stop` / `reinit` 手动控制（无参数仍为状态面板）。模块可在系统运行中手动拉起，不依赖开机脚本执行过；停止时同步完成守护进程停止与参数恢复，不把恢复留给后续开机流程。
- 每次启动重新读取原始参数：启动先重新初始化会话——上个会话遗留的未恢复应用记录先按其快照恢复（遗留数据只作恢复依据），随后清空 DEF/APPLIED，原始值由 capture_all 从当前节点重新采集；遗留恢复不完整时拒绝启动（fail-closed），避免把已修改的值当原始值。
- 自测修复与扩充：修复第 30、33 节在非 root 环境下 $DATA 未导出导致夹具路径塌陷的问题（改用 $DATADIR）；新增第 34–38 节覆盖停止恢复、脏会话重新初始化、幂等停止、手动启停全周期（真实拉起 supervisor/daemon）、系统分区写入静态守卫。
- 不写入 boot、init_boot、system 等系统分区：模块只写 sysfs/procfs 运行时参数与自身数据目录（/data/adb/smoothflow）；静态守卫已纳入自测第 38 节。

## 验证

- 隔离自测 95 项通过、0 失败（root 与非 root 身份各一轮；非 root 即 GitHub CI 条件）。
- 锁压力测试 40 轮双进程场景通过（非 root 身份）。
- action.sh 手动控制端到端验证：start 拉起 supervisor/daemon、reinit 后基线重新采集（16 条原始值记录）、stop 后恢复并清空状态、无残留进程。
- 发布 ZIP 由 package.sh 构建，含 fail-closed 的 SF_* 残留检查。
- 真机测试：本候选版的生命周期变更尚未在 OPD2513 实机回归；rc1 已由维护者报告基本功能测试正常，rc2 参数仍待 A/B。

本候选版不宣称 FPS、帧时间、温度、功耗或续航有任何实测改善。
