#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.5 看门狗：daemon 意外退出时指数退避重试并对连续快速失败冷却
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

cleanup_supervisor() {
    _cs_now=$(read_node "$SUPIDF" 2>/dev/null)
    [ "$_cs_now" = "$$ $_supervisor_start" ] && rm -f "$SUPIDF" 2>/dev/null
    release_supervisor_lock
}
trap 'cleanup_supervisor; exit 0' HUP INT TERM
trap 'cleanup_supervisor' EXIT
log "supervisor 启动 pid=$$"
_backoff=10
_failures=0

while :; do
    is_stopped && { log "收到停止标记，supervisor 退出"; exit 0; }
    [ -f "$MODDIR/bin/daemon.sh" ] || { log "daemon.sh 缺失，supervisor 退出"; exit 1; }
    _daemon_started_at=$(date +%s 2>/dev/null); case "$_daemon_started_at" in ''|*[!0-9]*) _daemon_started_at=0 ;; esac
    sh "$MODDIR/bin/daemon.sh"
    is_stopped && { log "停止标记已置位，supervisor 退出"; exit 0; }
    _now=$(date +%s 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
    _runtime=0
    if [ "$_daemon_started_at" -gt 0 ] 2>/dev/null && [ "$_now" -ge "$_daemon_started_at" ] 2>/dev/null; then
        _runtime=$((_now - _daemon_started_at))
    fi
    _backoff_state=$(supervisor_backoff_update "$_runtime" "$_failures" "$_backoff") || {
        log "supervisor 退避状态计算失败，安全退出"
        exit 1
    }
    set -- $_backoff_state
    _failures=$1; _backoff=$2; _trip=$3
    if [ "$_trip" = 1 ]; then
        log "daemon 连续快速失败 ${_failures} 次，触发 15 分钟熔断冷却"
        _cool=900
        while [ "$_cool" -gt 0 ]; do
            is_stopped && { log "冷却期间收到停止标记，supervisor 退出"; exit 0; }
            _step=10; [ "$_cool" -lt 10 ] && _step=$_cool
            sleep "$_step"
            _cool=$((_cool - _step))
        done
        _failures=0
        _backoff=10
        continue
    fi
    log "daemon 退出（运行 ${_runtime}s），${_backoff}s 后重试；连续快速失败=${_failures}"
    _wait=$_backoff
    while [ "$_wait" -gt 0 ]; do
        is_stopped && { log "等待重试期间收到停止标记，supervisor 退出"; exit 0; }
        _step=10; [ "$_wait" -lt 10 ] && _step=$_wait
        sleep "$_step"
        _wait=$((_wait - _step))
    done
done
