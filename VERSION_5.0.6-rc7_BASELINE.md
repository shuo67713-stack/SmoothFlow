# SmoothFlow v5.0.6-rc7 基线说明

- 版本：v5.0.6-rc7，versionCode 512。
- 基线：v5.0.6-rc6 源码树（versionCode 511）原样复制，仅应用一份定点补丁。
- 补丁来源：ChatGPT 官网（项目「SmoothFlow 审查」对话「生成定点修复补丁」，2026-11-13）按构建方核实后的 R1–R6 处置清单产出的 unified diff（构建方存档：工作区 rc7/gpt-rc7.patch）。补丁原文有两处 hunk 行数标注错误（daemon 兜底 hunk +16 应为 +15；selftest 大 hunk -19/+57 应为 -20/+58），构建方仅修正标注数字，未改动补丁内容本身，修正后 `patch -p1` 干净应用、上下文全匹配。
- 变更文件：bin/core.sh（lock_owner_stale 顺序、三处还原留痕、stop_daemon 身份保留）、tests/selftest.sh（§51 证据断言、§55 扩充、§56 新增）。其余运行文件与 rc6 逐字节一致（版本头与文档除外）。
- 调度参数：与 rc6/rc5 逐项一致（本版零参数改动）。
- 身份与门禁：未放宽任何属主校验或安全门禁；所有新增分支保持 fail-closed。
