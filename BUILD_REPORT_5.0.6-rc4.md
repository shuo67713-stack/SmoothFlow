# SmoothFlow 5.0.6-rc4 构建与测试报告

## 输入与变更

- 源码输入：用户上传的 `SmoothFlow_5.0.6-rc3_Source (1).zip`；原始压缩包未覆盖，所有改动在独立工作副本完成。
- 对照基线：GitHub `shuo67713-stack/SmoothFlow` 的 `v5.0.5` 标签，核对 `bin/core.sh`、`bin/daemon.sh`、`bin/supervisor.sh`、`service.sh`。
- 修复：daemon 原子单实例锁；Supervisor 指数退避与 900 秒熔断；严格 PID+starttime stale `.reap` 恢复；session 生命周期锁；启动失败回滚；stop 状态文件错误检查；PID 文件缺失/过期时回退检查锁目录进程身份；卸载串行化。
- 测试新增：退避状态机、daemon/session 锁、陈旧/活跃 reap gate、锁目录 PID 回退、capture 失败、初始档位部分写入失败、Supervisor 启动失败、停止标记写入失败。

## 验证结果

- Shell 语法：运行脚本与测试脚本全部通过 `sh -n`。
- 隔离自测：104 项通过、0 失败；以当前 Root 用户和 `nobody` 非 Root 用户分别执行，均通过。
- 锁压力测试：默认 5 轮；profile/supervisor/daemon/session 四类锁各执行 5 轮双进程互斥，共 20 轮；另通过 15 个 legacy stale/active 锁夹具及 1 个严格 session gate 夹具。
- 发布 ZIP 解包验证：发布版运行脚本语法通过；发布版 `bin/core.sh` 不含 SF_* 测试覆盖变量；非 Root 环境下 ZIP 内自测 104 项通过；ZIP 内锁压力测试 12 轮双进程互斥及 16 个 stale/active gate 夹具通过。
- 交付物：安装包 `dist/SmoothFlow_5.0.6-rc4_OPD2513.zip`；源码包 `dist/SmoothFlow_5.0.6-rc4_Source.zip`（含完整源码树、rc3→rc4 差异补丁和安装包）。两份 ZIP 均附 `.sha256` 校验文件。
- SHA-256：见对应 `.sha256` 文件；不在报告正文内重复维护易失效的散列值。
- 故障注入：快照采集失败、初始档位部分写入失败、Supervisor 启动失败、停止标记不可写均按预期返回失败/回滚/保留恢复记录。
- 系统分区静态守卫：运行时脚本未发现 boot/init_boot/system 分区写入目标。
- `shellcheck`：当前构建环境未安装，未执行 ShellCheck。

## 未验证事项与边界

- 未在 OPD2513 真机安装、启动、停止或卸载；未验证 KernelSU Next / SukiSU 临时注入 Root 的实际设备行为。
- 未执行性能、FPS、帧时间、温度、功耗或续航测试；本版不宣称性能改善。
- CPU 调度参数与 rc3 保持一致，没有改动 CPU 频率目标、hispeed_load、down_rate_limit_us、uclamp 或 GPU/温控策略。
- 未执行任何设备写入；本构建只对源码与 ZIP 进行本地操作。
