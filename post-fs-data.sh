#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.5 开机早期阶段：仅初始化日志和本启动周期状态，不写调度节点。
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

: > "$LOG" 2>/dev/null
: > "$DEF" 2>/dev/null
: > "$APPLIED" 2>/dev/null
log "=== 开机 $(getprop ro.build.display.id 2>/dev/null) ==="

# post-fs-data 阶段不采集参数：此时厂商服务可能还会调整调度节点。
# 原始值由 service.sh 在 boot_completed 后采集；每次实际写入前还会按节点补检。
