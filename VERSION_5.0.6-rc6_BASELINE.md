# SmoothFlow 5.0.6-rc6 基线说明

- 源码起点：5.0.6-rc5 完整源码树（小金构建，交付物 `SmoothFlow_5.0.6-rc5_Source.zip`，SHA-256 `f87345531285f97f3b24c3faa3ab75c338b84b3fe9f23b46894281eb82b1cc71`），处理副本位于独立工作目录，rc5 原始交付未覆盖。
- 修复依据：ChatGPT 官网总审（2026-11-13，评级不通过 B−）的问题清单 M1-A / M1-B / T1，及舰队核查遗留的发布守卫条目（DeepSeek）；全部条目均经构建方对 rc5 源码逐项核实后才动手，核实记录见构建报告。

## 与 rc5 的差异（全部）

| 文件 | 变更 |
|------|------|
| bin/core.sh | `recover_unproven_reap_gate` 补改名后属主记录复查（内容变化或出现可解析记录则还原不删）；`reap_gate_owner_stale`、`lock_owner_stale` 在比对 starttime 前增加数字格式校验；`lock_profile`、`acquire_supervisor_lock`、`reap_lock_dir` 补发布前 starttime 可读守卫；文件头版本号 |
| tests/selftest.sh | §51 断言改为逐操作返回码语义（stop 恒 0、双 start 至多一败、终态自洽）；新增 §54（迟到属主记录两项确定性注入）、§55（非数字 starttime 记录矩阵）；`run()` 夹具为子进程建模假 /proc 自身 stat；文件头版本号 |
| module.prop | version=v5.0.6-rc6，versionCode=511 |
| action.sh、bin/daemon.sh、bin/supervisor.sh、service.sh、post-fs-data.sh、config.example.sh | 仅版本号（action.sh 含面板三处文案） |
| scripts/package.sh | 打包文档清单与 ZIP 名改为 rc6 |
| README.md、NOTICE.md、BUILD.md、CHANGELOG.md、COOLAPK_POST.md | 版本与状态描述更新；BUILD.md 删除过时差异表述；COOLAPK_POST 由 5.0.4 草稿刷新；CHANGELOG 新增 rc6 条目 |
| RELEASE_NOTES_v5.0.6-rc6.md、VERSION_5.0.6-rc6_BASELINE.md、BUILD_REPORT_5.0.6-rc6.md | 新增（替代打包清单中的 rc5 文档） |

- CPU 调度参数与 rc5 逐项一致（游戏档 hispeed_load 78、down_rate_limit_us 10000 等），本版未改任何参数值。
- 未删除或弱化任何已有安全机制；rc5 的 111 项自测断言中仅 §51 一条按实测语义改写（由弱断言改强），其余未改；新增 3 项，总数 114。
- 释放路径（release_daemon_lock / release_supervisor_lock / release_session_lock）的整行比对 + 获取期缓存 starttime 回退经复查维持现状：记录须同时含本进程 PID 与获取期 starttime 才释放，回退不降低身份标准（中转 Claude 总审的信息项，构建方复查后决定不改行为，仅在此注明）。
