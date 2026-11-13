# SmoothFlow 5.0.6-rc5 基线说明

- 源码起点：用户上传的 `SmoothFlow_5.0.6-rc4_Source` 源码包（GPT 构建，小金独立审计通过 B+），处理副本位于独立工作目录，原始压缩包未覆盖。
- 对照基线：5.0.5 正式版源码（仅用于 A4 的 `unlock_profile` 逐字恢复与 M1 语义对照）。

## 与 rc4 的差异（全部）

| 文件 | 变更 |
|------|------|
| bin/core.sh | 新增 `gate_has_owner_record`、`recover_unproven_reap_gate`；`recover_stale_reap_gate` 增加严格证明失败后的分流；`unlock_profile` 恢复 5.0.5 的 PID+starttime 双校验；文件头版本号 |
| tests/selftest.sh | 新增第 48–53 节故障注入测试；文件头版本号 |
| action.sh | 面板三处遗留 rc2 文案改为 rc5；文件头版本号 |
| module.prop | version=v5.0.6-rc5，versionCode=510 |
| bin/daemon.sh、bin/supervisor.sh、service.sh、post-fs-data.sh、config.example.sh | 仅文件头版本号 |
| scripts/package.sh | 打包清单与 ZIP 名改为 rc5 |
| README.md、NOTICE.md、BUILD.md、CHANGELOG.md | 版本与状态描述更新；CHANGELOG 新增 rc5 条目 |
| RELEASE_NOTES_v5.0.6-rc5.md、VERSION_5.0.6-rc5_BASELINE.md、BUILD_REPORT_5.0.6-rc5.md | 新增（替代打包清单中的 rc4 文档） |

- CPU 调度参数与 rc4 逐项一致（游戏档 hispeed_load 78、down_rate_limit_us 10000 等），本版未改任何参数值。
- 未删除或弱化任何已有安全机制；原有 104 项自测断言一条未改。
