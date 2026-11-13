# SmoothFlow 5.0.6-rc3 基线说明

- 代码基线：5.0.6-rc2 源码树（其上游为 5.0.6-rc1 / 5.0.4 Patch3 ReviewFix）。
- 与 rc2 的代码差异：bin/core.sh（新增会话生命周期一节、版本标识）、service.sh（改调 sf_start）、action.sh（手动控制分发、版本标识）、post-fs-data.sh（注释与版本标识）、bin/daemon.sh 与 bin/supervisor.sh（仅版本标识）、tests/selftest.sh（$DATA 修复 + 第 34–38 节）、scripts/package.sh（产物名与文档清单）、module.prop（v5.0.6-rc3 / versionCode 508）、config.example.sh（注释）。
- 调度参数：与 rc2 逐值一致，未做任何调整。
- 未核对项：与已发布 5.0.5 正式源码的逐文件差异仍未核对（三方对照建议保留）；GitHub main 当前为已发布的 rc1 源码，rc3 未推送。
