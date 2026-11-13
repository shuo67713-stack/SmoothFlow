#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

log "开始安全卸载"
if ! sf_stop; then
    log "卸载中止：生命周期停止/恢复未完整完成；保留 $DATADIR 中的快照和恢复记录，请检查日志后重试"
    exit 1
fi
log "卸载恢复流程完成；未改写系统分区"
# 只有确认恢复完成且生命周期锁已释放后才归档整个数据目录。
if ! trash_path "$DATADIR"; then
    log "卸载数据归档失败：保留 $DATADIR，需排查后手动重试"
    exit 1
fi
