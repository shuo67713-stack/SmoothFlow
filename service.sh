#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.5 启动阶段
# 顺序：等待 boot_completed → 确认 CPU 拓扑 → 补快照 → 按屏幕状态应用 → 启动守护
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
done
[ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] || { log "系统启动未完成，跳过服务启动"; exit 0; }

# cpufreq 节点可能晚于 boot_completed 出现；每 2 秒探测，最多 60 秒。
ready=0
n=0
while [ "$n" -lt 30 ]; do
    device_ok && { ready=1; break; }
    sleep 2
    n=$((n + 1))
done
if [ "$ready" != 1 ]; then
    if ! device_identity_ok; then
        log "设备身份不匹配或 GPU 标识节点不可用；拒绝启动调度守护"
        exit 0
    fi
    log "CPU 拓扑/WALT 节点在 $((n * 2)) 秒内未就绪；不写入参数，交给守护进程安全重试"
else
    log "CPU policy 检查完成（等待 $((n * 2))s）：低=$CPU0 高=$CPU6 容量=$CPU_LOW_SCORE/$CPU_HIGH_SCORE"
fi

# 主锁残留仍由 core.sh 串行化回收；启动阶段另调用受限的 gate 恢复函数。

# 已有守护进程先停掉，避免与启动阶段的应用竞争
if [ -f "$PIDF" ] || [ -f "$SUPIDF" ]; then
    stop_daemon || { log "旧守护进程未能确认停止，拒绝启动新实例"; exit 1; }
fi

# 只有在旧守护进程已停止后，才恢复被 SIGKILL 留下的陈旧 .reap 门禁。
# 活跃 action/锁持有者的 PID+启动时间会阻止清理；不确定状态保持 fail-closed。
recover_stale_reap_gates || log "部分回收门禁未能安全恢复；相关锁操作将继续 fail-closed"

if [ "$ready" = 1 ]; then
    # 系统启动完成且目标节点就绪后，才采集厂商最终值。
    capture_all
    if [ "$(screen_state)" = 1 ]; then
        apply_on && log "启动阶段已应用日常档" || log "启动阶段日常档应用未完成，守护进程将继续重试"
    else
        apply_off
    fi
else
    write_state off ""
fi

[ -f "$PROFILEF" ] || set_profile auto
set_stopped 0

if ! supervisor_alive; then
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$MODDIR/bin/supervisor.sh" >/dev/null 2>&1 &
    else
        ( sh "$MODDIR/bin/supervisor.sh" >/dev/null 2>&1 & )
    fi
fi

_start_wait=0
while [ "$_start_wait" -lt 10 ]; do
    supervisor_alive && break
    sleep 0.2
    _start_wait=$((_start_wait + 1))
done
if supervisor_alive; then
    log "service 阶段完成（supervisor 已确认运行）"
else
    log "service 阶段完成但 supervisor 未确认启动；保持不写入状态并保留日志"
fi
