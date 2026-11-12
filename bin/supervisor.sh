#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.6-rc1 看门狗：daemon 意外退出时按 10 秒退避重新拉起
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/core.sh"

if ! acquire_supervisor_lock; then
    log "supervisor 已运行或锁状态不明确，拒绝重复启动"
    exit 0
fi

supervisor_alive && { release_supervisor_lock; log "检测到已有 supervisor 实例，拒绝重复启动"; exit 0; }
_supervisor_start=$(proc_start_time $$ 2>/dev/null) || _supervisor_start=
_supervisor_pid_tmp="$SUPIDF.tmp.$$"
if ! printf '%s %s\n' "$$" "$_supervisor_start" > "$_supervisor_pid_tmp" 2>/dev/null || ! mv -f "$_supervisor_pid_tmp" "$SUPIDF" 2>/dev/null; then
    rm -f "$_supervisor_pid_tmp" 2>/dev/null
    release_supervisor_lock
    log "supervisor PID 文件写入失败，退出"
    exit 1
fi

_supervisor_daemon_pid=
cleanup_supervisor() {
    # supervisor 收到外部信号时，先通知前台 daemon 子进程退出，再释放自身锁。
    if [ -n "$_supervisor_daemon_pid" ]; then
        set_stopped 1
        kill -TERM "$_supervisor_daemon_pid" 2>/dev/null || :
        wait "$_supervisor_daemon_pid" 2>/dev/null || :
        _supervisor_daemon_pid=
    fi
    _cs_now=$(read_node "$SUPIDF" 2>/dev/null)
    [ "$_cs_now" = "$$ $_supervisor_start" ] && rm -f "$SUPIDF" 2>/dev/null
    release_supervisor_lock
}
_supervisor_signal_exit() {
    trap - HUP INT TERM
    cleanup_supervisor
    exit 0
}
trap '_supervisor_signal_exit' HUP INT TERM
trap 'cleanup_supervisor' EXIT
log "supervisor 启动 pid=$$"

while :; do
    is_stopped && { log "收到停止标记，supervisor 退出"; exit 0; }
    [ -f "$MODDIR/bin/daemon.sh" ] || { log "daemon.sh 缺失，supervisor 退出"; exit 1; }
    sh "$MODDIR/bin/daemon.sh" &
    _supervisor_daemon_pid=$!
    wait "$_supervisor_daemon_pid"
    _supervisor_daemon_pid=
    is_stopped && { log "停止标记已置位，supervisor 退出"; exit 0; }
    log "daemon 退出，10 秒后重新拉起"
    sleep 10
done
