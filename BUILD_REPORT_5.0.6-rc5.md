# SmoothFlow 5.0.6-rc5 构建与测试报告

## 输入与变更

- 源码输入：用户上传的 `SmoothFlow_5.0.6-rc4_Source` 源码包；原始压缩包未覆盖，所有改动在独立工作副本完成。
- 依据：小金《SmoothFlow_5.0.6-rc4_独立审计报告》的 M1（中危）、A4（低危）与 P2 一致性条目。定点修复，不重写项目，不删除既有安全机制，不弱化任何既有断言。
- M1 修复（bin/core.sh）：新增 `gate_has_owner_record`（判定 gate 是否有可解析的 PID+starttime 属主记录）与 `recover_unproven_reap_gate`（无属主记录 gate 的时限恢复协议：年龄 >30 秒、间隔 1 秒双重观察 inode/mtime/记录内容不变、原子改名到本进程隔离路径并复核 inode 后才删除隔离副本，绝不直接删除公共 gate 路径）；`recover_stale_reap_gate` 在严格证明失败时分流——有命名属主的 gate 仍 fail-closed 保留，无属主记录的才走时限协议。
- A4 修复（bin/core.sh）：`unlock_profile` 恢复 5.0.5 的 PID+starttime 整行双校验，经与 5.0.5 源码逐字比对一致；记录缺失、损坏或不匹配时不解锁（安全失败）。
- P2：action.sh 面板三处 rc2 文案改为 rc5；NOTICE 的 rc1 描述改写为 rc5 实测口径；全部版本号统一 v5.0.6-rc5 / versionCode 510；README 状态与检查结果同步为 111 项。
- 与 rc4 的源码差异经全量 diff 复核：bin/core.sh 仅上述两处逻辑变更（63 行），其余文件仅版本号/文案；调度参数默认值与 rc4 逐项一致（hispeed_load 78、down_rate_limit_us 10000 等）。

## 测试（构建方亲自执行，隔离沙箱、网络断开、真实 /proc）

- Shell 语法：全部运行时与测试脚本 `sh -n` 通过。
- 隔离自测（源码树）：**111 项通过、0 失败**，分别以 root 与 nobody 非 root 执行，结果一致。构成：原有 104 项（断言未改、未弱化）+ 新增第 48–53 节 7 项断言。
- 新增故障注入（第 48–53 节，均为真实注入而非恒真断言）：
  - §48 无 pid 记录的陈旧 gate 经时限协议恢复；新鲜无主 gate 必须保留（fail-closed）。
  - §49 gate 记录矩阵：记录损坏（乱码）、仅 PID 无 starttime 的陈旧 gate 可恢复；记录指向活进程但 starttime 不符（PID 复用）可证明回收；记录指向活进程且 starttime 一致（活属主）必须保留。
  - §50 unlock_profile 身份矩阵：同 PID 不同 starttime 不解锁、记录损坏不解锁、双校验一致才解锁。
  - §51 并发 start/start/stop：session 锁串行化后最终状态自洽（完整启动态或完整停止态），无 session 锁泄漏。
  - §52 uninstall 真实执行：停止标记不可写时卸载中止、数据与节点原样保留；正常时先恢复节点原值再归档数据目录。
  - §53 真实进程注入：子进程创建 gate 后在发布 pid 前被 SIGKILL，陈旧化后 sf_start 端到端成功且 gate 被清除（M1 原始场景回归）。
  - 开发过程中三处新测试曾失败并已定位修正（均为测试夹具把 /proc 指向假目录所致，改用真实 /proc 后通过；其中 §52 的负向用例因此改为在预定失败点——停止标记写入——处验证，未降低断言强度）。
- 锁压力（nobody，默认配置）：PASS——profile/supervisor/daemon/session 四类锁各 5 轮双进程互斥（共 20 轮）+ 15 个 legacy stale/active 锁夹具 + 1 个严格 session gate 夹具。注：unlock_profile 的新双校验在该压力下经 profile 锁路径实际 exercised。
- 发布 ZIP 解包验证：sha256 与随附 .sha256 一致；发布版 bin/core.sh 经打包脚本门禁确认无 SF_ 测试覆盖入口残留（运行时状态变量 SF_WRITE_FAILED 等不属测试入口）；ZIP 内自测以 nobody 执行 **111 项通过、0 失败**，与源码树结果一致。
- 系统分区静态审计：对全部运行时脚本与打包脚本以宽口径扫描（/dev/block、by-name、init_boot、dd、fastboot、mount remount、mke2fs、blockdev 等），零命中；自测 §47 守卫同结论。

## 交付物清单（与实物逐项一致）

- `dist/SmoothFlow_5.0.6-rc5_OPD2513.zip`（安装包，21 个文件）
- `dist/SmoothFlow_5.0.6-rc5_OPD2513.zip.sha256`
- `dist/SmoothFlow_5.0.6-rc5_Source.zip`（完整源码树 + 本报告）
- `dist/SmoothFlow_5.0.6-rc5_Source.zip.sha256`
- SHA-256 以各 `.sha256` 文件为准，不在正文重复维护易失效的散列值。

## 未验证事项与边界

- 未在 OPD2513 真机安装、启动、停止或卸载；未验证 KernelSU Next / SukiSU 临时注入 Root 的实际设备行为。
- 未执行性能、FPS、帧时间、温度、功耗或续航测试；本版不宣称性能改善。
- CPU 调度参数与 rc4 保持一致，未改动任何频率目标、hispeed_load、down_rate_limit_us、uclamp 或 GPU/温控策略。
