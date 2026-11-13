# SmoothFlow 5.0.6-rc2 构建与测试报告

- 基线：5.0.6-rc1；rc1 基于 5.0.4 Patch3 ReviewFix，尚未与 5.0.5 正式源码逐文件核对。
- 本轮 CPU 调整：游戏档 `hispeed_load` 低/高 policy 80→78；`down_rate_limit_us` 8000→10000 µs。
- 未调整：hispeed/rtg 频率目标、scaling_min/max、uclamp、日常档、省电档、daemon 节拍；未增加 GPU、温控、在线核心数或系统分区写入。
- 目的：让游戏负载稍早触发 hispeed，并略微放缓降频节奏，作为温和的响应性实验。该方案可能增加高频驻留、功耗或温度，尚无量化帧时间/温度/功耗数据证明收益。
- Shell 语法检查：通过（action/service/post-fs-data/uninstall/core/daemon/supervisor/package/selftest/lock_stress）。
- 隔离自测：90 项通过，0 项失败。
- 锁压力测试：`ROUNDS=5`，10 轮双进程场景通过。
- 发布包构建：成功；发布 core 的 SF_* 测试环境覆盖残留检查由 package.sh fail-closed 门禁执行。
- 设备侧：维护者报告 rc1 真机基本功能测试正常；rc2 CPU 调度变化尚未进行独立 A/B 性能验收。
- 结论：可作为 5.0.6-rc2 实验候选，不应宣称性能/续航/温度已提升。
