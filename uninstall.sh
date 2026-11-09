#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

log "开始安全卸载"
stop_daemon
if restore_all; then
    log "卸载恢复流程完成；未改写系统分区"
    # 只有确认恢复流程完成后才归档快照；失败时保留数据供重试。
    trash_path "$DATADIR"
else
    log "卸载恢复失败：保留 $DATADIR 中的快照和恢复记录，需排查后手动重试"
    exit 1
fi
