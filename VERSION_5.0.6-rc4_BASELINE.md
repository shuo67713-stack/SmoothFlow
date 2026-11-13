# SmoothFlow 5.0.6-rc4 基线说明

- 源码起点：用户提供的 `SmoothFlow_5.0.6-rc3_Source (1).zip`（本次处理副本）。
- 回归基线：GitHub `shuo67713-stack/SmoothFlow` 的 `v5.0.5` 标签；恢复 daemon lock、Supervisor backoff/circuit breaker、stale reap gate 启动恢复。
- 新增：session 生命周期锁；start/stop/reinit 内部事务拆分；启动失败回滚与 stop 状态文件检查；stop 在 PID 文件缺失/过期时回退检查锁目录 PID+starttime；卸载统一调用 `sf_stop`。
- 测试：98 项隔离自测（含原 95 项与 3 项新增专项）及四类锁竞争压力测试；最终数据见构建报告。
- CPU 调度参数：与 rc3 保持一致，不改 hispeed_load、down_rate_limit_us、频率目标、uclamp 或其他档位值。
- 设备：目标仍为 OPD2513 / Android 16；本版未在用户真机执行安装、运行或卸载测试。
- Root：支持在 Root 有效时手动调用 action；KernelSU Next/SukiSU 临时注入重启后 Root 失效的特性不变。
- 安全边界：不写 boot/init_boot/system 分区，不增加 GPU/温控写入。运行时只操作白名单 sysfs/procfs 节点与 `/data/adb/smoothflow` 状态目录。
