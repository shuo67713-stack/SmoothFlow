#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.4 看门狗：daemon 意外退出时按 10 秒退避重新拉起
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/core.sh"

if ! acquire_supervisor_lock; then
    log "supervisor 已运行或锁状态不明确，拒绝重复启动"
    exit 0
fi

_supervisor_start=$(proc_start_time $$ 2>/dev/null) || _supervisor_start=
if ! printf '%s %s\n' "$$" "$_supervisor_start" > "$SUPIDF" 2>/dev/null; then
    release_supervisor_lock
    log "supervisor PID 文件写入失败，退出"
    exit 1
fi

cleanup_supervisor() {
    _cs_now=$(read_node "$SUPIDF" 2>/dev/null)
    [ "${_cs_now%% *}" = "$$" ] && rm -f "$SUPIDF" 2>/dev/null
    release_supervisor_lock
}
trap 'cleanup_supervisor; exit 0' HUP INT TERM
trap 'cleanup_supervisor' EXIT
log "supervisor 启动 pid=$$"

while :; do
    is_stopped && { log "收到停止标记，supervisor 退出"; exit 0; }
    [ -f "$MODDIR/bin/daemon.sh" ] || { log "daemon.sh 缺失，supervisor 退出"; exit 1; }
    sh "$MODDIR/bin/daemon.sh"
    is_stopped && { log "停止标记已置位，supervisor 退出"; exit 0; }
    log "daemon 退出，10 秒后重新拉起"
    sleep 10
done
