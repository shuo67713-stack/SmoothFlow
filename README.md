# SmoothFlow 5.0.6-rc7 — OPD2513（复核再修复候选版）

**面向 OnePlus Pad 3 Pro（OPD2513）的低开销 CPU 调度模块。**

SmoothFlow 根据屏幕状态和前台应用切换 CPU 调度档位，采用逐节点快照、写入归属记录和条件恢复机制，尽量避免与厂商服务或其它调度模块争抢参数。

> **当前状态：5.0.6-rc7 复核再修复候选版；本地隔离自测 116 项通过，锁压力测试通过。尚未在 OPD2513 真机安装/回归，不宣称 FPS、帧时间、温度、功耗或续航改善。**

## 项目范围

| 项目 | 说明 |
|---|---|
| 目标设备 | OnePlus Pad 3 Pro，设备标识 OPD2513 |
| 硬件识别 | SM8850P / Adreno 840，并要求识别到两组性能等级不同且成员互斥的 CPU policy |
| 运行环境 | Android Root 模块目录 `/data/adb/modules/smoothflow` |
| 管理器 | 以 SukiSU Ultra / KernelSU 模块安装流程为主要目标；其它管理器需自行验证 |
| 主要机制 | WALT 参数、CPU scaling min/max、可选 cgroup uclamp |
| 守护节拍 | 10 秒；仅在状态变化或检测到偏差时执行相应处理 |
| 默认模式 | 自动 / 日常 / 省电 |

**不支持的设备会被安全门禁拒绝写入。** 即使芯片型号相近，也不能据此推断 CPU policy、WALT 节点或内核行为完全一致。

## 功能

- **自动模式**：根据 top-app cgroup 识别前台游戏；找不到 cgroup 时回退到 `dumpsys` 识别路径。
- **日常模式**：采用轻量 WALT 参数，不主动抬高 CPU 最低频率。
- **省电模式**：限制 CPU 最高频率；不改 GPU 频率，也不绕过厂商温控。
- **条件恢复**：记录原始值和本模块最后写入值；恢复前校验节点白名单、值格式及写入归属。
- **冲突保护**：发现厂商或其它模块改写了同一节点时跳过，不强行覆盖。
- **进程清理**：daemon 退出时按 PID 与进程启动时间校验清理自身记录，避免正常退出后留下陈旧 PID 文件。
- **状态面板**：展示 CPU/GPU 读取状态、当前模式和守护进程状态；面板中的 GPU 读数仅作监测，不参与调参。

## 5.0.6-rc7 生命周期与复核修复

- daemon 单实例启动使用原子锁；Supervisor 恢复指数退避与连续快速失败熔断。
- service/action 的 start、stop、reinit 由独立 session 锁串行化。
- 启动快照失败或初始档位应用失败时中止启动；部分写入按归属记录回滚。
- Supervisor 启动失败时先停止可识别子进程，再尝试恢复；身份不明或恢复失败时保留快照并返回失败。
- `.reap` 恢复要求有效 PID+启动时间证明；身份不确定时 fail-closed。rc5 起，无属主记录的陈旧 gate 可按时限+双重观察协议安全恢复，不再永久拒绝启动（M1）。
- `unlock_profile` 恢复 PID+starttime 双校验，防止 PID 复用误解锁（A4）。
- 卸载走统一 `sf_stop` 路径，避免与手动启停并发。
- rc7 再修复（按 rc6 独立审查合并清单，由 ChatGPT 产出补丁、构建方落地验证）：lock_owner_stale 判定顺序与 reap_gate_owner_stale 对齐（僵尸优先于 starttime 格式）；三处隔离副本还原失败/跳过时日志留痕并复验 inode；stop_daemon 对「存活 PID + 非数字 starttime + 锁记录缺失」保留原始身份并 fail-closed；自测 §51 增加拒绝原因日志断言、§55 补僵尸格并改动态死 PID、新增 §56 发布守卫负向测试。
- rc6 复核修复（按 ChatGPT 官网总审核实成立的条目定点处理）：无主 gate 时限协议补齐隔离改名后的属主记录复查，迟到记录出现时还原不删（M1-A）；属主存活判定要求 starttime 为数字，非数字即记录损坏、不得冒充死亡证明（M1-B）；`lock_profile`、`acquire_supervisor_lock`、`reap_lock_dir` 补齐发布前守卫，自身 starttime 读不到时拒绝发布残缺属主记录。

详细变更和验证边界见 `RELEASE_NOTES_v5.0.6-rc7.md` 与 `BUILD_REPORT_5.0.6-rc7.md`。

## 安全边界

SmoothFlow 的写入范围由运行时识别出的白名单限定，主要包括：

- WALT 调度参数；
- CPU policy 的 `scaling_min_freq` / `scaling_max_freq`；
- 系统实际暴露且可读写的 display / top-app `cpu.uclamp.min` 节点。

以下内容明确不在写入范围内：

- `system`、`vendor`、`product`、`odm`、`boot`、`init_boot`、`vendor_boot` 等系统或启动分区；
- GPU governor、GPU 频率、Power Level；
- thermal zone、温控阈值、温控服务开关；
- 内存、IO、在线核心数等未列入白名单的节点。

模块写入的是运行时 sysfs / cgroup 参数，不代表对所有设备、内核版本或厂商配置都安全。发生卡顿、异常发热、耗电或不稳定时，应先执行恢复命令并停用模块。

## 安装与升级

1. 确认设备为 OPD2513，并保留当前可回滚的模块 ZIP。
2. **升级前先恢复旧版本参数**，在 Root Shell 执行：

   ```sh
   su
   sh /data/adb/modules/smoothflow/action.sh restore
   ```

   必须看到恢复成功。若恢复失败，先查看日志，不要直接覆盖旧版本。
3. 在 SukiSU Ultra / KernelSU 模块管理器中选择“从本地安装”，安装 `SmoothFlow_5.0.6-rc7_OPD2513.zip`。
4. 重启设备。
5. 重启后执行检查：

   ```sh
   su
   sh /data/adb/modules/smoothflow/action.sh check
   sh /data/adb/modules/smoothflow/action.sh debug
   sh /data/adb/modules/smoothflow/action.sh log
   ```

6. 先验证亮屏、熄屏、游戏进入、游戏退出和恢复流程，再进行长时间使用测试。

## 常用命令

```sh
su
sh /data/adb/modules/smoothflow/action.sh check    # 检查拓扑与受管节点
sh /data/adb/modules/smoothflow/action.sh debug    # 输出诊断信息
sh /data/adb/modules/smoothflow/action.sh log      # 查看最近日志
sh /data/adb/modules/smoothflow/action.sh mode auto
sh /data/adb/modules/smoothflow/action.sh mode daily
sh /data/adb/modules/smoothflow/action.sh mode eco
sh /data/adb/modules/smoothflow/action.sh stop     # 停止守护进程
sh /data/adb/modules/smoothflow/action.sh restore  # 停止并尝试恢复受管参数
sh /data/adb/modules/smoothflow/action.sh start    # 重新启动守护进程
```

如果恢复提示失败，模块会保留未完成的恢复记录。请保存日志和诊断输出，先排查冲突，不要手动批量写入 sysfs 节点。

## 可选配置

模块默认使用内置参数。需要自定义时，将 `config.example.sh` 复制为：

```text
/data/adb/smoothflow/config.sh
```

只接受代码中明确列出的白名单键和纯数字参数；配置文件不会作为 Shell 脚本执行。频率值单位为 kHz，模块会按设备公开的 `scaling_available_frequencies` 对齐。修改配置后建议先停止守护进程，再重启或重新启动模块服务。

不要照搬其它机型的频率值。配置不当可能影响续航、温度和稳定性。

## 测试

本仓库提供隔离自测：测试脚本会创建假的 sysfs、procfs、cgroup 目录，不访问真实设备节点。

```sh
sh -n action.sh
sh -n service.sh
sh -n post-fs-data.sh
sh -n uninstall.sh
sh -n bin/core.sh
sh -n bin/daemon.sh
sh -n bin/supervisor.sh
sh tests/selftest.sh
```

**本次 5.0.6-rc7 候选构建检查结果：** Shell 语法检查通过；隔离自测 116 项通过、0 项失败（root 与非 root 均通过；个别轮次为 115 项，差异为 §51 条件证据断言是否触发）；锁压力测试通过（四类锁各 5 轮双进程互斥及 16 个门禁夹具）。测试在隔离目录执行，不代表 OPD2513 真机回归，也不能证明游戏帧率、温度、功耗或续航有所改善。rc6 按 ChatGPT 官网总审（2026-11-13）核实成立的 M1-A、M1-B 等条目定点修复 rc5，补齐三处属主记录发布守卫并新增对应回归测试；详细边界见构建报告。

## 项目结构

```text
.
├── module.prop
├── post-fs-data.sh
├── service.sh
├── action.sh
├── uninstall.sh
├── config.example.sh
├── bin/
│   ├── core.sh
│   ├── daemon.sh
│   └── supervisor.sh
├── tests/
│   └── selftest.sh
├── webroot/
│   └── index.html
├── scripts/
│   └── package.sh
├── .github/workflows/test.yml
├── CHANGELOG.md
├── BUILD.md
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── NOTICE.md
└── LICENSE
```

## 参与贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。提交问题时请附设备型号、系统版本、内核版本、Root 管理器版本、复现步骤和脱敏后的 `check` / `debug` 输出。不要上传包含个人数据的完整日志。

## AI 辅助开发说明

项目部分代码由生成式 AI 辅助起草，后续经过维护者审查、修改和测试。`module.prop` 中的 `author` 按维护者指定显示为“硕”。AI 生成内容不代表真实设备验证；最终发布和兼容性责任由维护者承担。详见 [NOTICE.md](NOTICE.md)。

## 许可证

本仓库采用 GNU General Public License v3.0（GPL-3.0-only）。分发本项目或其衍生作品时，应遵守 GPL-3.0 的完整条款，并保留版权与许可证声明。

### 恢复语义与边界

- 基线是模块在本次启动周期内、首次写入某个节点之前成功读取的值，不等同于 ROM 出厂值。
- 只有当节点当前值仍等于 SmoothFlow 最后一次登记的写入值时，模块才会恢复基线。
- 如果检测到其它服务或模块已改写该节点，SmoothFlow 会放弃该节点的管理并保留外部值；因此卸载不保证覆盖外部接管后的值。
- 节点不可读、不可写或快照不完整时，模块采取 fail-closed：跳过对应写入或报告恢复失败，不伪报成功。
- 锁回收使用短时 `.reap` 门禁；若该门禁在持有期间遭到不可捕获的 SIGKILL，模块会拒绝继续争抢锁，重启后可清除残留状态。


## 致谢与研究参考

以下项目仅作为设计研究参考；本项目不声明直接复制或重新分发其源码：

- [KernelSU-Tuner](https://github.com/ylh440104/KernelSU-Tuner)
- [AKTune](https://github.com/iodn/android-kernel-tweaker)
- [Encore](https://github.com/Rem01Gaming/encore)
- [FAS-RS](https://github.com/shadow3aaa/fas-rs)
- [KernelSU 模块开发文档](https://github.com/tiann/KernelSU/blob/730f644615969cfd4a84b45d7f62a667b7b95a50/website/docs/zh_CN/guide/module.md)

SmoothFlow 与 OnePlus、酷安、SukiSU Ultra、KernelSU 均无官方隶属关系。
