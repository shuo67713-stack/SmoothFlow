#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.6-rc7 启动阶段
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

# 锁回收统一由 core.sh 的串行化回收协议负责；service 不独立拆锁。

# 启停统一走 core.sh 的会话生命周期（sf_start）：持有 session 锁，先停旧守护、恢复 stale gate、重新初始化
# 会话状态（遗留未恢复记录先恢复再清空）、重读原始参数、应用档位、拉起
# supervisor。手动启动（action.sh start）与开机启动共用同一路径。
sf_start "$ready"
_sf_service_rc=$?
[ "$_sf_service_rc" = 0 ] || log "service 启动未完成（rc=$_sf_service_rc）；请检查日志，未确认启动前不视为成功"
exit "$_sf_service_rc"
