# SmoothFlow 5.0.6-rc6 构建与测试报告

## 输入与变更

- 源码输入：5.0.6-rc5 完整源码树（交付物 `SmoothFlow_5.0.6-rc5_Source.zip`，SHA-256 `f87345531285f97f3b24c3faa3ab75c338b84b3fe9f23b46894281eb82b1cc71`）；原始交付未覆盖，所有改动在独立工作副本完成。
- 依据：ChatGPT 官网总审（2026-11-13，评级不通过 B−）的问题清单中经构建方逐项对 rc5 源码核实成立的条目（M1-A、M1-B、T1；T2、V1 的处置见下），及舰队核查遗留的发布守卫条目（DeepSeek）。定点修复，不重写项目，不删除既有安全机制，不弱化任何既有断言（§51 为由弱改强，见下）。
- M1-A 修复（bin/core.sh）：`recover_unproven_reap_gate` 在隔离改名并复核 inode 后，删除前再读隔离副本的 pid 记录——内容与观察期不一致、或出现可解析属主记录时，一律改名还原并返回失败，与严格证明路径 `recover_stale_reap_gate` 的改名后复查对齐。
- M1-B 修复（bin/core.sh）：`reap_gate_owner_stale` 与 `lock_owner_stale` 在 PID 存活、需比对 starttime 时先验数字格式，非数字（记录损坏）不判陈旧；PID 已不存在/僵尸时死亡由缺席证明，不受此限。`gate_has_owner_record` 有意保持宽松（有第二字段即视为有命名属主）——它决定 fail-closed 保留分流，宽松只会更保守。
- 发布守卫补齐（bin/core.sh）：`lock_profile`、`acquire_supervisor_lock`、`reap_lock_dir` 在发布属主记录前新增「自身 starttime 读不到则清理并拒绝」守卫，与 daemon/session 两锁既有守卫一致。说明：DeepSeek 原报两处（lock_profile、reap_lock_dir），构建方复查全部发布点后确认共三处（supervisor 同样缺失）。
- 未采纳/维持现状的条目（附理由）：① 释放路径整行比对 + 获取期缓存 starttime 回退（中转 Claude 信息项）——记录须同时含本进程 PID 与获取期 starttime 才释放，回退不降低身份标准，维持现状；② T2（§53 未走生产 reap 代码制造 gate）——临界点（mkdir 后、发布前）无法在不改生产代码的前提下确定性拦截，维持场景模拟 + §54 的确定性注入补强竞态侧；③ V1（ChatGPT 环境自测 §51 附近 200 秒超时）——本构建环境 6 轮全套自测均约 38 秒内完成（见下），倾向其运行器对后台子进程的管道继承等待差异，记为未决环境差异，不据此认定产品死锁。

## 测试（构建方亲自执行，隔离沙箱、网络断开、真实 /proc）

- Shell 语法：全部运行时与测试脚本 `sh -n` 通过。
- 隔离自测（源码树）：**114 项通过、0 失败**。构成：rc5 的 111 项 + 新增 3 项（§54 两项、§55 一项）；其中 §51 一项按实测语义改写（见下），其余 110 项断言未改。
  - 最终树实测：nobody 两轮、root 一轮，均 114/114；§51 改写前的探针树 nobody 三轮亦 114/114。
  - §51 改写说明：原断言只要求三个并发操作返回码「全是数字」。探针三轮实测分布为 000 / 000 / 010——stop 恒 0、双 start 至多一个以 1 干净失败（竞争落败并回滚，终态仍自洽）。断言据此改为逐操作语义：返回码组合只允许 000 / 010 / 100 且终态自洽。这是把弱断言改强，不是通过不了而放宽。
  - §54（新增，M1-A 回归）：(a) 记录在 1 秒观察窗内由后台进程迟到发布——gate 与记录一并保留；(b) 以函数桩包装 `mv`，在隔离改名完成后、删除前向隔离副本植入可解析属主记录（确定性复现竞态结果）——改名后复查必须发现并把 gate 原样还原、无隔离残留。
  - §55（新增，M1-B 回归）：记录矩阵——「活 PID + 非数字 starttime」必须保留（不冒充死亡证明）；「死 PID + 非数字 starttime」可证明回收。
  - 夹具变更（如实披露）：新增发布守卫后，未建模的夹具曾让 apply 家族 30 项确定性失败——`run()` 子进程是真实进程，但夹具假 /proc 没有它的 stat 条目，守卫按设计拒绝发布。修复方式是补全夹具模型：`run()` 在每个块执行前把子进程自身 stat 建模进假 /proc（starttime 固定 424242，仅供身份比对）；需要真实身份语义的条目仍在块内改用真 /proc（套件既有惯例）。生产代码未为测试做任何让步。
- 锁压力（nobody，默认配置）：PASS——profile/supervisor/daemon/session 四类锁各 5 轮双进程互斥（共 20 轮）+ 15 个 legacy stale/active 锁夹具 + 1 个严格 session gate 夹具。
- 发布 ZIP 解包验证：sha256 与随附 .sha256 一致；发布版 bin/core.sh 经打包脚本门禁确认无 SF_ 测试覆盖入口残留（运行时状态变量 SF_WRITE_FAILED 等不属测试入口）；ZIP 内自测以 nobody 执行 **114 项通过、0 失败**，与源码树结果一致。
- 系统分区静态审计：对全部运行时脚本与打包脚本以宽口径扫描（/dev/block、by-name、init_boot、dd、fastboot、mount remount、mke2fs、blockdev 等），零命中；自测 §47 守卫同结论。

## 交付物清单（按交付目录实物表述）

交付目录（`~/workspace/your_files/` 与目标文件区）内并列交付以下四件，SHA-256 以各 `.sha256` 文件为准，不在正文重复维护易失效的散列值：

- `SmoothFlow_5.0.6-rc6_OPD2513.zip`（安装包，21 个文件）
- `SmoothFlow_5.0.6-rc6_OPD2513.zip.sha256`
- `SmoothFlow_5.0.6-rc6_Source.zip`（完整源码树 + 本报告）
- `SmoothFlow_5.0.6-rc6_Source.zip.sha256`

口径说明（修正 rc5 报告的 D1 表述）：源码包内部的 `dist/` 含安装包及其 `.sha256`；源码包自身与其 `.sha256` 是交付目录中的并列文件，不在任何压缩包内部（压缩包无法包含自身）。

## 未验证事项与边界

- 未在 OPD2513 真机安装、启动、停止或卸载；未验证 KernelSU Next / SukiSU 临时注入 Root 的实际设备行为。
- 未执行性能、FPS、帧时间、温度、功耗或续航测试；本版不宣称性能改善。
- CPU 调度参数与 rc5 保持一致，未改动任何频率目标、hispeed_load、down_rate_limit_us、uclamp 或 GPU/温控策略。
