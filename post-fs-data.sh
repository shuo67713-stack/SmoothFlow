#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.6-rc7 开机早期阶段：仅初始化日志和本启动周期状态，不写调度节点。
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

: > "$LOG" 2>/dev/null
: > "$DEF" 2>/dev/null
: > "$APPLIED" 2>/dev/null
log "=== 开机 $(getprop ro.build.display.id 2>/dev/null) ==="

# post-fs-data 阶段不采集参数：此时厂商服务可能还会调整调度节点。
# 原始值由启动路径（service.sh / 手动启动）在拓扑就绪后采集；每次实际
# 写入前还会按节点补检。此处开机清空只适用于「节点随重启复位」的情形；
# 同一启动周期内的手动重启不经过本脚本，其遗留状态由 core.sh 的
# reinit_session 在启动时处理（先按遗留快照恢复，再清空重读）。
