# SmoothFlow 5.0.4 — Muse 第三轮综合审查说明（Patch 2）

## 审查目标

本候选包基于第二轮报告的 M1–M4 进行集中修复，并处理少量有明确证据、低风险的加固项。它仍是审查包，不是已完成 OPD2513 真机验证的正式发布版。

## 已处理项目

### M1：配置热变更后频率节点残留
- `restore_eco_caps()` 不再用当前 `ECO_MAX*` 配置反推历史写入值；改为按 `applied.txt` 归属记录调用 `restore_one_if_owned()`。
- `settle_min()` 先检查路径的实际写入归属；仅当当前值仍等于本模块最后写入值时才恢复基线，再按当前档位目标重新抬升。
- 新增两项回归测试：省电档中途修改 `ECO_MAX6` 后进入日常档；游戏档中途将 `GAME_MIN0` 改为 0 后进入日常档。

### M2：profile/supervisor 锁回收竞态
- 移除 `service.sh` 自行清理 profile.lock 的独立逻辑。
- profile 与 supervisor 锁统一使用短时 `.reap` gate 串行化残留回收；竞争者在创建主锁后再次检查 gate，避免旧锁被判死后新锁刚创建时被另一回收者误拆。
- 回收通过将旧目录移动到唯一隔离目录后删除；只在确认属主进程不存在或启动时间不匹配时回收。
- 空 PID 锁需超过 30 秒才回收；活 PID 但启动时间不可读取时 fail-closed。
- `.reap` gate 若在持有期间遭 SIGKILL 留下，会导致后续锁操作 fail-closed，直至重启清理；这是为避免递归回收竞态作出的保守取舍，请第三轮重点评估是否有更好的 Android Shell 原语。
- 新增 `tests/lock_stress.sh`：使用真实 `/proc` 和两个独立 Shell 进程，对两类锁分别进行双进程残留锁竞争测试。

### M3：stop_daemon 停止结果不可靠
- TERM 等待后仍存活的目标才尝试 KILL；KILL 后再等待并复核。
- 若 PID 仍存在且启动时间相同/无法确认，返回非零并保留 PID 记录；僵尸态 Z/X 视为已停止。
- `action.sh` 的 stop/off/restore、`service.sh` 启动旧实例清理及 `uninstall.sh` 均检查停止返回值。
- stop 失败时 off/restore 不继续写恢复节点；卸载中止，不归档数据目录。
- PID 文件采用临时文件 + `mv` 发布；supervisor 清理按 PID+启动时间比对；daemon 增加单实例自检。
- 新增 stop 失败/成功隔离测试。

### M4：许可证统一
- 全包 SPDX 标识统一为 `GPL-3.0-only`。
- `LICENSE` 使用完整 GPL-3.0 文本。
- README、CHANGELOG、发布说明和检查清单同步许可证说明。
- 此前可用的 5.0.4 源码归档实际仍含 MIT 标识；本候选包已按维护者既定决策统一为 GPL-3.0-only，发布前仍需核对全部纳入内容的授权来源。

### 额外低风险加固
- daemon 每约 60 秒重新探测 top-app cgroup；若启动时尚未就绪，后续可自动切换到 procfs 快路径，避免永久使用 dumpsys 兜底。
- `capture()` 遇到同一路径畸形空快照行时先剔除旧行再写入，避免重复路径导致 `def_of()` 永远读到空值。
- README 明确基线是本启动周期首次写入前采集值，不承诺等同 ROM 出厂值；外部模块接管节点后，SmoothFlow 放弃覆盖该节点。

## 未修改项目

- 未调整任何 ON/GAME/ECO 频率、负载、uclamp、rate-limit 数值。
- 未修改 10 秒 daemon 主轮询周期。
- 未改变设备身份、双 policy 拓扑、WALT 节点等 fail-closed 门禁。
- 未自动切换 governor；不改 GPU、温控、系统分区或原生调度器。

## 本地验证

- `sh -n`：全部 Shell 脚本通过。
- `sh tests/selftest.sh`：83 项通过，0 项失败。
- `ROUNDS=20 sh tests/lock_stress.sh`：40 轮双进程残留锁竞争（profile 20 轮 + supervisor 20 轮）通过。
- 尚未完成 Android mksh/Toybox 验证、真实设备安装/卸载、真实 sysfs 节点、WALT governor 语义、uclamp 量化及性能开销测量。

## 第三轮请重点复核

1. `.reap` gate 在 SIGKILL 遗留时的恢复策略是否可接受，是否存在可证明安全的自动恢复替代方案。
2. M1 两个配置变更探针是否覆盖所有档位切换顺序，尤其 ECO→GAME、GAME→ECO、ON_MIN 非零。
3. `stop_daemon()` 在 Android mksh 下对 `/proc/<pid>/cmdline` NUL 格式的身份判定；确认 PID 复用、僵尸进程和 PID 文件并发更新。
4. supervisor/daemon 单实例自检与 supervisor lock 的交互，避免自我误判或锁泄漏。
5. Toybox `stat -c %Y`、`mv` 目录改名、`rm -rf`、`sleep 0.2` 在目标 Android 环境的实际支持情况。
6. 是否需要为 `tests/lock_stress.sh` 增加 Android 设备可执行模式；当前压力测试在 Linux 主机上以真实 `/proc` 执行。
7. 复查 GPL-3.0-only 是否与所有实际纳入内容的授权来源一致；许可证选择不替代作者对版权归属的确认。

## 发布边界

本候选包没有在 OPD2513 真机执行命令、没有写真实 `/sys`、没有安装或卸载。83 项隔离测试与 40 轮主机双进程锁测试不等于 Android 真机验证。不要直接将此审查包作为正式安装版发布。
