#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.4 操作面板 / 状态可视化
case "$0" in */*) MODDIR=$(cd "${0%/*}" && pwd) ;; *) MODDIR=$(pwd) ;; esac
. "$MODDIR/bin/core.sh"

# ---------------- 小工具 ----------------
bar() {
    p=${1:-0}
    case "$p" in ''|*[!0-9]*) p=0 ;; esac
    [ "$p" -gt 100 ] && p=100
    filled=$((p * 10 / 100))
    s=""
    i=0
    while [ "$i" -lt 10 ]; do
        if [ "$i" -lt "$filled" ]; then s="$s█"; else s="$s░"; fi
        i=$((i + 1))
    done
    printf '%s' "$s"
}

pct() {
    m=${2:-0}
    case "$m" in ''|*[!0-9]*) printf '0\n'; return ;; esac
    [ "$m" -lt 1 ] && { printf '0\n'; return; }
    c=${1:-0}
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    printf '%s\n' $((c * 100 / m))
}

mhz() {
    c=${1:-0}
    case "$c" in ''|*[!0-9]*) printf '0\n'; return ;; esac
    printf '%s\n' $((c / 1000))
}

gb() {
    v=${1:-0}
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    awk -v k="$v" 'BEGIN{printf "%.1f", k/1048576}'
}

# 纯 Shell 读取，避免为面板刷新启动 awk 子进程
mem_kb() {
    while IFS= read -r _mk_line; do
        case "$_mk_line" in
            "$1:"*) set -- $_mk_line; printf '%s\n' "$2"; return 0 ;;
        esac
    done < "$PROC/meminfo" 2>/dev/null
    return 1
}

swap_field() { # 第 2 行第 N 列（3=total, 4=used）
    _sfw_idx=$1
    _sfw_n=0
    while IFS= read -r _sfw_line; do
        _sfw_n=$((_sfw_n + 1))
        [ "$_sfw_n" = 2 ] || continue
        set -- $_sfw_line
        case "$_sfw_idx" in
            3) printf '%s\n' "${3:-}" ;;
            4) printf '%s\n' "${4:-}" ;;
            *) return 1 ;;
        esac
        return 0
    done < "$PROC/swaps" 2>/dev/null
    return 1
}

mode_label() {
    case "$1" in
        off)  printf '熄屏 · 已还原厂商参数\n' ;;
        on)   printf '亮屏 · 日常档\n' ;;
        game) printf '游戏 · 性能调度\n' ;;
        eco)  printf '省电模式\n' ;;
        *)    printf '未知（守护进程尚未写入状态）\n' ;;
    esac
}

ver_of() {
    while IFS= read -r _vo; do
        case "$_vo" in version=*) printf '%s\n' "${_vo#version=}"; return 0 ;; esac
    done < "$MODDIR/module.prop" 2>/dev/null
}

# ---------------- 状态面板 ----------------
draw_status() {
    mode=$(state_get mode 2>/dev/null) || mode="?"
    [ -n "$mode" ] || mode="?"
    ver=$(ver_of)
    [ -n "$ver" ] || ver="v?"
    gpkg=$(state_get pkg 2>/dev/null) || gpkg=

    ram_total=$(mem_kb MemTotal)
    ram_avail=$(mem_kb MemAvailable)
    ram_used=$(( ${ram_total:-0} - ${ram_avail:-0} ))

    z_used=$(swap_field 4)
    z_total=$(swap_field 3)

    c0=$(read_node "$CPU0/scaling_cur_freq" 2>/dev/null) || c0=
    c0m=$(read_node "$CPU0/scaling_max_freq" 2>/dev/null) || c0m=
    c6=$(read_node "$CPU6/scaling_cur_freq" 2>/dev/null) || c6=
    c6m=$(read_node "$CPU6/scaling_max_freq" 2>/dev/null) || c6m=

    gclk=$(read_node "$GPU/gpuclk" 2>/dev/null) || gclk=
    gmax=$(read_node "$GPU/max_clock_mhz" 2>/dev/null) || gmax=
    gbusy=$(gpu_busy_value 2>/dev/null) || gbusy=
    bstat=$(read_node "$SYS/class/power_supply/battery/status" 2>/dev/null) || bstat=
    gm=$(( ${gclk:-0} / 1000000 ))

    printf '\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf ' SmoothFlow 5.0.4 低开销调度引擎 · %s\n' "$ver"
    printf ' 设备 OPD2513 · CPU policy 动态识别\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf ' 系统  %s · %s\n' "$(getprop ro.build.version.release)" "$(getprop ro.build.display.id)"
    if [ -d /data/adb/modules/thermaloff ]; then
        tm=$(awk -F= '$1=="mode"{print $2}' /data/adb/thermaloff/state 2>/dev/null)
        [ -n "$tm" ] || tm="?"
        printf ' 温控  ThermalOff %s\n' "$tm"
    fi
    printf ' 档位  %s\n' "$(mode_label "$mode")"
    [ -n "$gpkg" ] && printf ' 前台  %s\n' "$gpkg"
    if daemon_alive; then
        printf ' 守护  运行中 · 10s 节拍 · procfs 快路径\n'
    else
        printf ' 守护  未运行（action.sh start）\n'
    fi
    printf ' 拓扑  %s 低=%s(%s) 高=%s(%s)\n' \
        "$([ "$CPU_TOPOLOGY_OK" = 1 ] && printf 正常 || printf 未通过)" \
        "${CPU0##*/}" "$CPU_LOW_SCORE" "${CPU6##*/}" "$CPU_HIGH_SCORE"

    printf '\n── 处理器 ────────────────────\n'
    printf ' 低性能簇 %5s/%5s MHz %s %s%%\n' "$(mhz "$c0")" "$(mhz "$c0m")" "$(bar "$(pct "$c0" "$c0m")")" "$(pct "$c0" "$c0m")"
    printf ' 高性能簇 %5s/%5s MHz %s %s%%\n' "$(mhz "$c6")" "$(mhz "$c6m")" "$(bar "$(pct "$c6" "$c6m")")" "$(pct "$c6" "$c6m")"
    printf ' 在线核 %s\n' "$(read_node "$CPU_ROOT/online" 2>/dev/null)"

    printf '\n── 图形 ──────────────────────\n'
    printf ' 图形 %4s/%4s MHz %s %s%%\n' "$gm" "${gmax:-0}" "$(bar "$(pct "$gm" "$gmax")")" "$(pct "$gm" "$gmax")"
    printf ' 负载 %3s%%\n' "${gbusy:-0}"

    printf '\n── 内存 ──────────────────────\n'
    printf ' RAM  %s/%s G %s %s%%\n' "$(gb "$ram_used")" "$(gb "$ram_total")" "$(bar "$(pct "$ram_used" "$ram_total")")" "$(pct "$ram_used" "$ram_total")"
    printf ' zram %s/%s G\n' "$(gb "${z_used:-0}")" "$(gb "${z_total:-0}")"
    printf ' 电池状态 %s\n' "${bstat:-未知}"

    printf '\n── 已应用 ────────────────────\n'
    if [ "$(read_node "$W0/hispeed_freq" 2>/dev/null)" = "$ON_HS0" ] \
       || { [ "$mode" = game ] && [ "$(read_node "$W0/hispeed_freq" 2>/dev/null)" = "$GAME_HS0" ]; }; then a="✓"; else a="·"; fi
    dcur=
    [ -n "$DISPLAY_UCLAMP_PATH" ] && dcur=$(read_node "$DISPLAY_UCLAMP_PATH" 2>/dev/null) || dcur=
    if [ -n "$dcur" ] && ! pct_matches "$dcur" 0; then d="✓"; else d="·"; fi
    if [ "$mode" = game ]; then e="✓"; else e="·"; fi
    if game_forced; then f="开"; else f="关"; fi
    if [ "$(read_node "$W0/down_rate_limit_us" 2>/dev/null)" = "$ON_DOWN_RATE" ]; then g="✓"; else g="·"; fi
    printf ' WALT %s  GPU 原厂  内存/IO 未干预  合成 %s\n' "$a" "$d"
    printf ' 限速 %s  游戏 %s  强制 %s  已应用 %s 项\n' "$g" "$e" "$f" "$(wc -l < "$APPLIED" 2>/dev/null || printf 0)"
    printf '\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf ' mode auto/daily/eco · on 日常 · off 还原\n'
    printf ' game on/off 强制游戏识别\n'
    printf ' log 日志 · config 配置 · check 自检\n'
    printf ' debug 调试信息 · frame 帧时间反馈状态 · restore 彻底还原 · start/stop 守护\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
}

# ---------------- 命令 ----------------
# 未确认目标设备时拒绝调度写入；恢复/停止/诊断命令仍允许执行。
case "$1" in
    on|game|start)
        if ! device_ok; then
            printf '错误：设备身份、CPU 拓扑或必需 WALT 节点未通过检查，已阻止调度参数写入。\n'
            exit 1
        fi
        ;;
esac

case "$1" in
    mode)
        case "$2" in
            auto|daily|eco)
                set_profile "$2" || exit 1
                printf '✓ 已切换到 %s 模式；守护进程将在下一节拍应用\n' "$2"
                ;;
            *) printf '用法：action.sh mode {auto|daily|eco}\n'; exit 2 ;;
        esac
        ;;
    on)
        rc=0
        apply_on || rc=$?
        if [ "$rc" = 0 ]; then
            write_state on ""
            printf '✓ 已应用亮屏档\n'
        elif [ "$rc" = 2 ]; then
            printf '✗ 设备身份/CPU 拓扑/WALT 安全检查未通过，未写入任何参数\n'
            exit 1
        else
            printf '✗ 亮屏档应用未完整成功；请查看日志，不应视为已生效\n'
            exit 1
        fi
        ;;
    off)
        if ! stop_daemon; then
            printf '✗ 守护进程未能确认停止；为避免并发写入，本次不执行恢复\n'
            exit 1
        fi
        if restore_all; then
            write_state off ""
            printf '✓ 已停止守护并恢复模块管理的参数\n'
        else
            printf '✗ 恢复未完成；保留恢复记录，请查看日志后重试\n'
            exit 1
        fi
        ;;
    game)
        case "$2" in
            on)
                set_game_force 1
                printf '✓ 已强制游戏档，守护进程将在下一节拍生效\n'
                ;;
            off)
                set_game_force 0
                printf '✓ 已关闭强制游戏档\n'
                ;;
            *)
                if game_forced; then printf '强制游戏档：开\n'; else printf '强制游戏档：关\n'; fi
                ;;
        esac
        ;;
    restore)
        set_game_force 0
        if ! stop_daemon; then
            printf '✗ 守护进程未能确认停止；为避免并发写入，本次不执行恢复\n'
            exit 1
        fi
        if restore_all; then
            write_state off ""
            printf '✓ 已停止守护并恢复模块管理的参数；如需重新运行，请执行 start\n'
        else
            printf '✗ 恢复未完成；保留恢复记录，请查看日志并重试\n'
            exit 1
        fi
        ;;
    webdata)
        printf 'ver=%s\n' "$(ver_of)"
        printf 'mode=%s\n' "$(state_get mode 2>/dev/null)"
        printf 'profile=%s\n' "$(get_profile)"
        printf 'pkg=%s\n' "$(state_get pkg 2>/dev/null)"
        printf 'forced=%s\n' "$(game_forced && printf 1 || printf 0)"
        printf 'daemon=%s\n' "$(daemon_alive && printf 1 || printf 0)"
        _p0_cur=$(read_node "$CPU0/scaling_cur_freq" 2>/dev/null) || _p0_cur=
        _p0_max=$(read_node "$CPU0/scaling_max_freq" 2>/dev/null) || _p0_max=
        _p6_cur=$(read_node "$CPU6/scaling_cur_freq" 2>/dev/null) || _p6_cur=
        _p6_max=$(read_node "$CPU6/scaling_max_freq" 2>/dev/null) || _p6_max=
        if [ -z "$_p0_cur" ]; then
            for _cpu in $(expand_cpu_list "$CPU_LOW_MEMBERS"); do
                _p0_cur=$(read_node "$CPU_ROOT/cpu$_cpu/cpufreq/scaling_cur_freq" 2>/dev/null) && [ -n "$_p0_cur" ] && break
            done
        fi
        if [ -z "$_p6_cur" ]; then
            for _cpu in $(expand_cpu_list "$CPU_HIGH_MEMBERS"); do
                _p6_cur=$(read_node "$CPU_ROOT/cpu$_cpu/cpufreq/scaling_cur_freq" 2>/dev/null) && [ -n "$_p6_cur" ] && break
            done
        fi
        printf 'p0_cur=%s\np0_max=%s\np6_cur=%s\np6_max=%s\n' "$_p0_cur" "$_p0_max" "$_p6_cur" "$_p6_max"
        printf 'topology=%s\n' "$([ "$CPU_TOPOLOGY_OK" = 1 ] && printf ok || printf invalid)"
        printf 'low_cpus=%s\nhigh_cpus=%s\n' "$CPU_LOW_MEMBERS" "$CPU_HIGH_MEMBERS"
        printf 'gpu_cur=%s\n' "$(( $(read_node "$GPU/gpuclk" 2>/dev/null || printf 0) / 1000000 ))"
        printf 'gpu_max=%s\n' "$(read_node "$GPU/max_clock_mhz" 2>/dev/null)"
        printf 'gpu_busy=%s\n' "$(gpu_busy_value 2>/dev/null)"
        printf 'ram_total=%s\n' "$(mem_kb MemTotal)"
        printf 'ram_avail=%s\n' "$(mem_kb MemAvailable)"
        printf 'swap_used=%s\nswap_total=%s\n' "$(swap_field 4)" "$(swap_field 3)"
        ;;
    debug)
        printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n SmoothFlow 5.0.4 调试信息\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
        printf ' 时间: %s   uptime: %s秒\n' "$(date '+%F %T')" "$(cut -d' ' -f1 "$PROC/uptime")"
        printf ' 内核: %s\n' "$(uname -r)"
        printf ' 模块: %s\n' "$(ver_of)"
        printf ' state: %s\n' "$(tr '\n' ' ' < "$STATEF" 2>/dev/null)"
        printf ' device_ok: %s\n' "$(device_ok && printf yes || printf no)"
        printf ' 快照: %s 项  已应用: %s 项  归属冲突: %s 项\n' "$(wc -l < "$DEF" 2>/dev/null || printf 0)" "$(wc -l < "$APPLIED" 2>/dev/null || printf 0)" "$(ownership_conflict_count)"
        printf ' 守护: daemon=%s supervisor=%s\n' "$(read_node "$PIDF" 2>/dev/null)" "$(read_node "$SUPIDF" 2>/dev/null)"
        printf ' 快路径: cgroup=%s\n' "$(front_cgroup_file 2>/dev/null || printf N/A)"
        printf ' -- 节点（当前 / 原厂）--\n'
        for f in $PROFILE_PATHS; do
            printf '  %-42s %-10s %s\n' "${f#"$SYS"/}" "$(read_node "$f" 2>/dev/null)" "$(def_of "$f")"
        done
        printf ' -- CPU 拓扑 --\n'
        printf '  topology_valid: %s（要求恰好两组、容量不同、成员互斥）\n' "$CPU_TOPOLOGY_OK"
        printf '  low:  %s cpus=%s score=%s governor=%s\n' "$CPU0" "$CPU_LOW_MEMBERS" "$CPU_LOW_SCORE" "$CPU0_GOV"
        printf '  high: %s cpus=%s score=%s governor=%s\n' "$CPU6" "$CPU_HIGH_MEMBERS" "$CPU_HIGH_SCORE" "$CPU6_GOV"
        printf '  GPU governor=%s busy=%s clock=%s\n' "$(read_node "$GPU/devfreq/governor" 2>/dev/null)" "$(gpu_busy_value 2>/dev/null)" "$(read_node "$GPU/gpuclk" 2>/dev/null)"
        printf '  uclamp display=%s top-app=%s\n' "${DISPLAY_UCLAMP_PATH:-unsupported}" "${TOP_APP_UCLAMP_PATH:-unsupported}"
        printf ' -- 游戏识别 --\n'
        printf '  规则 %s 字符  强制: %s\n' "${#GAME_PATTERNS}" "$(game_forced && printf 开 || printf 关)"
        printf ' -- 最近日志 --\n'
        [ -f "$LOG" ] && tail -n 15 "$LOG" || printf '  无日志\n'
        printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
        ;;
    start)
        if supervisor_alive; then
            if is_stopped; then
                set_stopped 0
                printf '✓ 已清除停止标记，现有守护进程将继续运行\n'
            else
                printf '✓ 守护进程已经运行，无需重复启动\n'
            fi
            exit 0
        fi
        stop_daemon || { printf '✗ 旧守护进程未能确认停止，拒绝启动新实例\n'; exit 1; }
        set_stopped 0
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$MODDIR/bin/supervisor.sh" >/dev/null 2>&1 &
        else
            (sh "$MODDIR/bin/supervisor.sh" >/dev/null 2>&1 &)
        fi
        _start_wait=0
        while [ "$_start_wait" -lt 10 ]; do
            supervisor_alive && break
            sleep 0.2
            _start_wait=$((_start_wait + 1))
        done
        if supervisor_alive; then
            printf '✓ 守护进程已启动（看门狗模式）\n'
        else
            printf '✗ supervisor 未能启动；请检查日志和模块目录\n'
            exit 1
        fi
        ;;
    stop)
        if stop_daemon; then
            printf '✓ 守护进程已停止\n'
        else
            printf '✗ 未能确认守护进程停止；请检查日志，勿视为成功\n'
            exit 1
        fi
        ;;
    frame)
        printf 'SmoothFlow 5.0.4 帧时间反馈状态\n'
        printf '状态：未启用\n'
        printf '原因：当前尚未在 OPD2513 上验证稳定、低开销且可归因到目标游戏的帧时间数据源。\n'
        printf '当前策略：继续使用已验证的 WALT / uclamp 调度路径。\n'
        printf '安全边界：不会把 GPU busy、CPU 频率或屏幕刷新率伪装成实际帧时间。\n'
        printf '本命令只显示状态，不读取或写入调度节点。\n'
        ;;
    log)
        if [ -f "$LOG" ]; then
            printf '最近日志（%s）：\n' "$LOG"
            tail -n 20 "$LOG"
        else
            printf '暂无日志\n'
        fi
        ;;
    config)
        if [ -f "$DATADIR/config.sh" ]; then
            printf '自定义配置 %s：\n' "$DATADIR/config.sh"
            cat "$DATADIR/config.sh"
        else
            printf '未创建自定义配置。\n路径：%s\n可覆盖的键（示例）：\n' "$DATADIR/config.sh"
            printf '  ON_HS0=2112000   ON_MIN0=1228800\n'
            printf '  TOP_UCLAMP=35    DISPLAY_UCLAMP=40\n'
            printf '  GAME_HS0=2361600 GAME_PATTERNS="com.xxx.* ..."\n'
        fi
        ;;
    check)
        printf '自检（拓扑 / 节点 / 原厂快照）：\n'
        bad=0
        if [ "$CPU_TOPOLOGY_OK" = 1 ]; then
            printf ' ✓ CPU policy：两组不同性能等级（%s / %s）\n' "$CPU_LOW_SCORE" "$CPU_HIGH_SCORE"
        else
            printf ' ✗ CPU policy：无法安全识别，模块将保持不写入\n'
            bad=$((bad + 1))
        fi
        if [ "$WALT_OK" = 1 ]; then
            printf ' ✓ WALT 节点可读（governor: %s / %s）\n' "$CPU0_GOV" "$CPU6_GOV"
        else
            printf ' ✗ WALT 节点缺失（governor: %s / %s）；调度参数不会生效\n' "$CPU0_GOV" "$CPU6_GOV"
            bad=$((bad + 1))
        fi
        for f in $PROFILE_PATHS; do
            if [ -e "$f" ]; then
                printf ' ○ %s = %s\n' "${f#"$SYS"/}" "$(read_node "$f" 2>/dev/null)"
            else
                printf ' ✗ 缺少 %s\n' "$f"
                bad=$((bad + 1))
            fi
        done
        printf ' -- 原厂快照 --\n'
        printf ' 已记录 %s 项；恢复记录 %s 项\n' "$(wc -l < "$DEF" 2>/dev/null || printf 0)" "$(wc -l < "$APPLIED" 2>/dev/null || printf 0)"
        _owner_conflicts=$(ownership_conflict_count)
        printf ' 节点归属冲突：%s 项（冲突节点不自动覆盖）\n' "$_owner_conflicts"
        _mode_now=$(state_get mode 2>/dev/null)
        case "$_mode_now" in
            on|game)
                _dr=$(drift_detect "$_mode_now")
                case "$_dr" in ''|*[!0-9]*) _dr=? ;; esac
                printf ' 策略关键项偏差：%s 项（当前 %s 档；不是全部节点完整性计数）\n' "$_dr" "$_mode_now"
                [ "$_dr" = 0 ] || bad=$((bad + 1))
                ;;
            eco) printf ' 漂移检查：省电档仅做上限约束，跳过\n' ;;
        esac
        printf ' ----\n'
        if [ "$bad" = 0 ]; then
            printf '✓ 全部检查通过\n'
        else
            printf '✗ 有 %s 项未通过（可能是系统版本或平台不支持）\n' "$bad"
            exit 1
        fi
        ;;
    *)
        draw_status
        ;;
esac
