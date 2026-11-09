#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.4 状态守护
# 节拍 10 秒；热路径只做 Shell 内建 procfs/sysfs 读取，不调用 dumpsys。
# 仅在状态变化时写 sysfs，参数不变时零写入。
MODDIR=$(cd "${0%/*}/.." && pwd)
. "$MODDIR/bin/core.sh"

_daemon_start=$(proc_start_time $$ 2>/dev/null) || _daemon_start=
[ -n "$_daemon_start" ] || {
    log "无法读取 daemon 启动时间，拒绝进入后台循环"
    exit 1
}
cleanup_daemon() {
    _cd_now=$(read_node "$PIDF" 2>/dev/null) || _cd_now=
    [ "$_cd_now" = "$$ $_daemon_start" ] && rm -f "$PIDF" 2>/dev/null
}
# 正常退出、停止标记退出及信号退出均清理自身 PID 文件；不碰其它实例的记录。
trap 'cleanup_daemon' EXIT
trap 'exit 0' HUP INT TERM
if ! printf '%s %s\n' "$$" "$_daemon_start" > "$PIDF" 2>/dev/null; then
    log "daemon PID 文件写入失败，拒绝进入后台循环"
    exit 1
fi
_daemon_saved=$(read_node "$PIDF" 2>/dev/null) || _daemon_saved=
if [ "$_daemon_saved" != "$$ $_daemon_start" ]; then
    log "daemon PID 文件读回校验失败，拒绝进入后台循环"
    exit 1
fi
log "守护进程启动 pid=$$ 节拍=10s 快路径=procfs"

state=""
pkg=""
last_profile=""
tick=0
prev_screen=""
topo_warn_tick=0

has_cg=0
front_cgroup_file >/dev/null 2>&1 && has_cg=1
cfg_mtime=
ss_warned=0
drift_hits=0
drift_hold=0
game_misses=0
[ "$has_cg" = 1 ] || log "未找到 top-app cgroup，游戏识别退回 dumpsys（较高开销）"

while :; do
    is_stopped && { log "收到停止标记，daemon 退出"; exit 0; }
    tick=$((tick + 1))

    # --- 配置热加载：每 10 个节拍（约 100s）检查一次 mtime，变更后重新读取 ---
    if [ $((tick % 10)) -eq 1 ]; then
        _cfg_m=
        [ -f "$DATADIR/config.sh" ] && _cfg_m=$(stat -c '%Y:%s' "$DATADIR/config.sh" 2>/dev/null)
        if [ "$_cfg_m" != "$cfg_mtime" ]; then
            cfg_mtime=$_cfg_m
            load_config
            validate_config
            state=""
            log "配置已变更，重新加载并重新应用档位"
        fi
    fi

    # --- 屏幕状态：先读背光/dpms；无法判定时每 6 个节拍才复核一次 PowerManager ---
    screen=$(screen_state)
    if [ -z "$screen" ] && [ "$ss_warned" = 0 ]; then
        ss_warned=1
        log "无法读取背光/dpms，改用限频 PowerManager 复核屏幕状态"
    fi
    if [ -z "$screen" ] && { [ $((tick % 6)) -eq 0 ] || [ -z "$prev_screen" ]; }; then
        screen=$(screen_state_power)
    fi
    [ -n "$screen" ] || screen=$prev_screen
    prev_screen=$screen

    if [ "$screen" != 1 ]; then
        if [ "$state" != off ]; then
            if apply_off; then
                state=off
                pkg=""
                if ! write_state off ""; then
                    log "熄屏档已恢复，但状态文件写入/校验失败"
                fi
                log "熄屏：模块管理的参数已恢复"
            else
                log "熄屏恢复未完成，下一轮重试"
            fi
        fi
        sleep 10
        continue
    fi

    profile=$(get_profile)
    forced=0
    game_forced && forced=1

    case "$profile" in
        eco)
            if [ "$state" != eco ]; then
                apply_eco && {
                    state=eco
                    pkg=""
                    write_state eco "" || log "省电档已应用，但状态文件写入/校验失败"
                    log "省电档已应用"
                }
            fi
            ;;
        daily)
            if [ "$state" != on ]; then
                apply_on && {
                    state=on
                    pkg=""
                    write_state on "" || log "日常档已应用，但状态文件写入/校验失败"
                    log "固定日常档已应用"
                }
            fi
            ;;
        *)
            if [ "$forced" = 1 ]; then
                game_pkg="手动开启"
            elif [ "$has_cg" = 1 ]; then
                game_pkg=$(detect_game_cgroup)
                if [ -n "$game_pkg" ]; then
                    game_misses=0
                elif [ "$state" = game ]; then
                    # 单次 top-app cgroup 漏检不立刻退出游戏档；连续两次未命中
                    # 才用 dumpsys 低频复核，避免游戏中短暂 PID/cgroup 抖动造成降档。
                    game_misses=$((game_misses + 1))
                    if [ "$(game_miss_policy "$state" "$game_misses")" = hold ]; then
                        game_pkg=$pkg
                    else
                        game_pkg=$(detect_game_dumpsys)
                        game_misses=0
                    fi
                else
                    game_misses=0
                    # 平时只在 60 秒一次的兜底点检查，兼顾漏检恢复与低开销。
                    [ $((tick % 6)) -ne 0 ] || game_pkg=$(detect_game_dumpsys)
                fi
            else
                game_misses=0
                game_pkg=$(detect_game_dumpsys)
            fi

            if [ -n "$game_pkg" ]; then
                if [ "$state" != game ] || [ "$pkg" != "$game_pkg" ]; then
                    rc=0
                    apply_game || rc=$?
                    if [ "$rc" = 0 ]; then
                        state=game
                        pkg=$game_pkg
                        write_state game "$pkg" || log "游戏档已应用，但状态文件写入/校验失败"
                        log "游戏档已应用：$pkg"
                    elif [ "$rc" = 2 ] && [ $((tick - topo_warn_tick)) -ge 6 ]; then
                        topo_warn_tick=$tick
                        log "游戏档暂不能应用：设备身份/CPU 拓扑/WALT 前置检查未通过，持续重试"
                    fi
                fi
            elif [ "$state" != on ]; then
                rc=0
                apply_on || rc=$?
                if [ "$rc" = 0 ]; then
                    state=on
                    pkg=""
                    write_state on ""
                    log "日常档已应用"
                elif [ "$rc" = 2 ] && [ $((tick - topo_warn_tick)) -ge 6 ]; then
                    topo_warn_tick=$tick
                    log "日常档暂不能应用：设备身份/CPU 拓扑/WALT 前置检查未通过，持续重试"
                fi
            fi
            ;;
    esac

    # --- 漂移检查：每 3 个节拍（约 30s）只读检查关键 WALT 项 ---
    # 后续档位重申经过 set_val 的节点归属检查；外部修改的节点不会被强行覆盖。
    case "$state" in
        on|game)
            if [ $((tick % 3)) -eq 0 ] && [ "$tick" -ge "$drift_hold" ]; then
                _drift=$(drift_detect "$state")
                case "$_drift" in ''|*[!0-9]*) _drift=0 ;; esac
                if [ "$_drift" -gt 0 ]; then
                    drift_hits=$((drift_hits + 1))
                    if [ "$drift_hits" -ge 4 ]; then
                        # 外部模块持续改写同一批节点：暂停自愈约 10 分钟，避免互相刷写。
                        drift_hits=0
                        drift_hold=$((tick + 60))
                        log "外部改写持续存在，漂移自愈暂停约 10 分钟"
                    else
                        if [ "$state" = game ]; then
                            apply_game >/dev/null 2>&1
                        else
                            apply_on >/dev/null 2>&1
                        fi
                        log "检测到 $_drift 项 WALT 目标偏差，已复核 $state 档；外部占用节点会被跳过"
                    fi
                else
                    drift_hits=0
                fi
            fi
            ;;
    esac

    last_profile=$profile
    sleep 10
done
