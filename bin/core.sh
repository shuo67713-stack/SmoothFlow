#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.4 核心库
# 只写 sysfs / procfs 下的运行时参数，不挂载、不修改任何分区。
# 所有改动在重启后失效；uninstall.sh 会把参数还原为本模块记录的原厂值。
#
# 4.0 设计要点：
#  1. 热路径（屏幕/前台/游戏识别）全部走 procfs + Shell 内建，不再调用 dumpsys。
#  2. 拓扑识别在每次应用前重新校验，避免一次瞬时失败导致整轮生命周期内失效。
#  3. 拓扑无效时 fail-closed：不写任何节点。
#  4. 路径可通过 SF_SYS / SF_PROC / SF_CG / SF_DATADIR 覆盖，仅用于隔离自测。

MODID=smoothflow
MODDIR=${MODDIR:-/data/adb/modules/$MODID}

# 仅测试用覆盖；生产环境保持默认真实路径。
SYS=${SF_SYS:-/sys}
PROC=${SF_PROC:-/proc}
CG=${SF_CG:-/dev/cpuctl}
DATADIR=${SF_DATADIR:-/data/adb/smoothflow}

LOG=$DATADIR/smoothflow.log
DEF=$DATADIR/defaults.txt
APPLIED=$DATADIR/applied.txt
PIDF=$DATADIR/daemon.pid
SUPIDF=$DATADIR/supervisor.pid
SUPLOCK=$DATADIR/supervisor.lock
STOPF=$DATADIR/stopped
TRASH=${SF_TRASH:-/data/adb/smoothflow_trash}

CPUFREQ_ROOT=$SYS/devices/system/cpu/cpufreq
CPU_ROOT=$SYS/devices/system/cpu
BL=$SYS/class/backlight/panel0-backlight/brightness
GPU=$SYS/class/kgsl/kgsl-3d0

umask 077
mkdir -p "$DATADIR" 2>/dev/null
chmod 700 "$DATADIR" 2>/dev/null

# ---------- 日志 ----------
_LOG_N=0
_LOG_READY=0
_log_rotate() {
    _log_tmp="$LOG.tmp.$$"
    if tail -n 200 "$LOG" > "$_log_tmp" 2>/dev/null; then
        mv -f "$_log_tmp" "$LOG" 2>/dev/null || rm -f "$_log_tmp" 2>/dev/null
    else
        rm -f "$_log_tmp" 2>/dev/null
    fi
}
log() {
    [ -n "$LOG" ] || return 0
    if [ "$_LOG_READY" = 0 ]; then
        _LOG_READY=1
        [ -f "$LOG" ] || : > "$LOG" 2>/dev/null
        _lz=$(wc -c < "$LOG" 2>/dev/null)
        case "$_lz" in ''|*[!0-9]*) _lz=0 ;; esac
        [ "$_lz" -gt 262144 ] && _log_rotate
    fi
    if [ $((_LOG_N % 8)) -eq 0 ] || [ -z "$_LOG_TS" ]; then
        _LOG_TS=$(date '+%m-%d %H:%M:%S')
    fi
    printf '[%s] %s\n' "$_LOG_TS" "$*" >> "$LOG" 2>/dev/null
    _LOG_N=$((_LOG_N + 1))
    if [ "$_LOG_N" -ge 500 ]; then
        _LOG_N=0
        _log_rotate
    fi
}

# ---------- 基础读取 ----------
# 全部使用 Shell 内建 read，不产生 cat 子进程。
read_node() {
    REPLY=
    [ -r "$1" ] || return 1
    IFS= read -r REPLY < "$1" 2>/dev/null || [ -n "$REPLY" ]
    [ -n "$REPLY" ] || return 1
    printf '%s\n' "$REPLY"
}

# ---------- CPU 拓扑 ----------
expand_cpu_list() {
    for _ec_word in $1; do
        _ec_rest=$_ec_word
        while [ -n "$_ec_rest" ]; do
            case "$_ec_rest" in
                *,*) _ec_item=${_ec_rest%%,*}; _ec_rest=${_ec_rest#*,} ;;
                *)   _ec_item=$_ec_rest; _ec_rest= ;;
            esac
            case "$_ec_item" in
                *-*)
                    _ec_a=${_ec_item%-*}; _ec_b=${_ec_item#*-}
                    case "$_ec_a" in ''|*[!0-9]*) continue ;; esac
                    case "$_ec_b" in ''|*[!0-9]*) continue ;; esac
                    [ "$_ec_a" -le "$_ec_b" ] 2>/dev/null || continue
                    while [ "$_ec_a" -le "$_ec_b" ]; do
                        printf '%s\n' "$_ec_a"
                        _ec_a=$((_ec_a + 1))
                    done
                    ;;
                *)
                    case "$_ec_item" in ''|*[!0-9]*) continue ;; esac
                    printf '%s\n' "$_ec_item"
                    ;;
            esac
        done
    done
}

cpu_list_contains() {
    _cl_n=$2
    case "$_cl_n" in ''|*[!0-9]*) return 1 ;; esac
    for _cl_c in $(expand_cpu_list "$1"); do
        [ "$_cl_c" = "$_cl_n" ] && return 0
    done
    return 1
}

policy_members() {
    _pm_v=$(read_node "$1/related_cpus") || _pm_v=$(read_node "$1/affected_cpus") || return 1
    printf '%s\n' "$_pm_v"
}

# 同一 policy 内所有 CPU 的 cpu_capacity 必须一致，否则拒绝作为可识别等级。
policy_capacity() {
    _pc_m=$(policy_members "$1") || return 1
    _pc_cpus=$(expand_cpu_list "$_pc_m")
    [ -n "$_pc_cpus" ] || return 1
    _pc_first=
    for _pc_cpu in $_pc_cpus; do
        _pc_v=$(read_node "$CPU_ROOT/cpu$_pc_cpu/cpu_capacity") || return 1
        case "$_pc_v" in ''|*[!0-9]*) return 1 ;; esac
        if [ -z "$_pc_first" ]; then
            _pc_first=$_pc_v
        elif [ "$_pc_v" != "$_pc_first" ]; then
            return 1
        fi
    done
    [ -n "$_pc_first" ] || return 1
    printf '%s\n' "$_pc_first"
}

find_cgroup_node() {
    for _fc_f in "$@"; do
        [ -e "$_fc_f" ] && { printf '%s\n' "$_fc_f"; return 0; }
    done
    return 1
}

# 只认可“恰好两组、容量不同、成员互斥”的拓扑；其余一律 fail-closed。
refresh_cpu_policies() {
    _rc_total=0
    _rc_bad=0
    _rc_ok=0
    _rc_low=
    _rc_high=
    _rc_lowc=
    _rc_highc=
    for _rc_p in "$CPUFREQ_ROOT"/policy*; do
        [ -d "$_rc_p" ] || continue
        _rc_total=$((_rc_total + 1))
        _rc_c=$(policy_capacity "$_rc_p") || { _rc_bad=$((_rc_bad + 1)); continue; }
        case "$_rc_c" in ''|*[!0-9]*) _rc_bad=$((_rc_bad + 1)); continue ;; esac
        _rc_ok=$((_rc_ok + 1))
        if [ -z "$_rc_lowc" ] || [ "$_rc_c" -lt "$_rc_lowc" ]; then
            _rc_lowc=$_rc_c
            _rc_low=$_rc_p
        fi
        if [ -z "$_rc_highc" ] || [ "$_rc_c" -gt "$_rc_highc" ]; then
            _rc_highc=$_rc_c
            _rc_high=$_rc_p
        fi
    done

    CPU0=${_rc_low:-/nonexistent/policy_low_capacity}
    CPU6=${_rc_high:-/nonexistent/policy_high_capacity}
    CPU_LOW_SCORE=${_rc_lowc:-unknown}
    CPU_HIGH_SCORE=${_rc_highc:-unknown}
    CPU_TOPOLOGY_OK=0

    if [ "$_rc_total" -eq 2 ] && [ "$_rc_bad" -eq 0 ] && [ "$_rc_ok" -eq 2 ] \
       && [ -n "$_rc_low" ] && [ -n "$_rc_high" ] && [ "$_rc_low" != "$_rc_high" ] \
       && [ -n "$_rc_lowc" ] && [ -n "$_rc_highc" ] && [ "$_rc_lowc" -lt "$_rc_highc" ]; then
        _rc_lm=$(policy_members "$_rc_low" 2>/dev/null)
        _rc_hm=$(policy_members "$_rc_high" 2>/dev/null)
        _rc_disjoint=1
        for _rc_cpu in $(expand_cpu_list "$_rc_lm"); do
            cpu_list_contains "$_rc_hm" "$_rc_cpu" && { _rc_disjoint=0; break; }
        done
        [ "$_rc_disjoint" = 1 ] && CPU_TOPOLOGY_OK=1
    fi

    CPU_LOW_MEMBERS=$(policy_members "$CPU0" 2>/dev/null) || CPU_LOW_MEMBERS=
    CPU_HIGH_MEMBERS=$(policy_members "$CPU6" 2>/dev/null) || CPU_HIGH_MEMBERS=
    CPU0_GOV=$(read_node "$CPU0/scaling_governor" 2>/dev/null) || CPU0_GOV=
    CPU6_GOV=$(read_node "$CPU6/scaling_governor" 2>/dev/null) || CPU6_GOV=

    W0=$CPU0/walt
    W6=$CPU6/walt
    WALT_OK=1
    for _wo_f in "$W0/hispeed_freq" "$W0/hispeed_load" "$W0/rtg_boost_freq" "$W0/down_rate_limit_us" \
                "$W6/hispeed_freq" "$W6/hispeed_load" "$W6/rtg_boost_freq" "$W6/down_rate_limit_us"; do
        [ -r "$_wo_f" ] && [ -w "$_wo_f" ] || WALT_OK=0
    done
    for _wo_f in "$CPU0/scaling_available_frequencies" "$CPU6/scaling_available_frequencies"; do
        [ -r "$_wo_f" ] || WALT_OK=0
    done

    DISPLAY_UCLAMP_PATH=$(find_cgroup_node "$CG/display/cpu.uclamp.min" "$SYS/fs/cgroup/display/cpu.uclamp.min" 2>/dev/null) || DISPLAY_UCLAMP_PATH=
    TOP_APP_UCLAMP_PATH=$(find_cgroup_node "$CG/top-app/cpu.uclamp.min" "$SYS/fs/cgroup/top-app/cpu.uclamp.min" 2>/dev/null) || TOP_APP_UCLAMP_PATH=

    PROFILE_PATHS="$W0/hispeed_freq $W0/hispeed_load $W0/rtg_boost_freq $W0/down_rate_limit_us $CPU0/scaling_min_freq $CPU0/scaling_max_freq $W6/hispeed_freq $W6/hispeed_load $W6/rtg_boost_freq $W6/down_rate_limit_us $CPU6/scaling_min_freq $CPU6/scaling_max_freq $DISPLAY_UCLAMP_PATH $TOP_APP_UCLAMP_PATH"
    [ -e "$W0/up_rate_limit_us" ] && PROFILE_PATHS="$PROFILE_PATHS $W0/up_rate_limit_us"
    [ -e "$W6/up_rate_limit_us" ] && PROFILE_PATHS="$PROFILE_PATHS $W6/up_rate_limit_us"
}

refresh_cpu_policies

# ---------- 可调参数 ----------
# 不接受调用环境注入的参数；所有参数使用模块默认值或受限配置文件。
unset ON_HS_POLICY ON_HS0 ON_LOAD0 ON_RTG0 ON_MIN0 ON_HS6 ON_LOAD6 ON_RTG6 ON_MIN6 ON_DOWN_RATE ON_MAX0 ON_UP_RATE \
      DISPLAY_UCLAMP TOP_UCLAMP GAME_UCLAMP GAME_HS0 GAME_LOAD0 GAME_RTG0 GAME_MIN0 GAME_HS6 GAME_LOAD6 GAME_RTG6 GAME_MIN6 GAME_DOWN_RATE GAME_UP_RATE \
      ECO_MAX0 ECO_MAX6 ECO_MIN0 ECO_MIN6 ECO_HS0 ECO_HS6 ECO_LOAD ECO_UCLAMP GAME_PATTERNS

# 日常档：轻量 WALT 调度，不抬高常驻最低频率
: "${ON_HS0:=1497600}"
: "${ON_LOAD0:=88}"
: "${ON_RTG0:=1209600}"
: "${ON_MIN0:=0}"
: "${ON_HS6:=1804800}"
: "${ON_LOAD6:=88}"
: "${ON_RTG6:=1497600}"
: "${ON_MIN6:=0}"
: "${ON_DOWN_RATE:=20000}"
: "${ON_UP_RATE:=0}"
: "${ON_MAX0:=0}"
: "${ON_HS_POLICY:=raise}"
: "${DISPLAY_UCLAMP:=10}"
: "${TOP_UCLAMP:=0}"
: "${GAME_UCLAMP:=20}"

# 游戏档：更快响应负载，不锁最高频、不抬最低频、不强制在线核心数
: "${GAME_HS0:=1804800}"
: "${GAME_LOAD0:=80}"
: "${GAME_RTG0:=1555200}"
: "${GAME_MIN0:=0}"
: "${GAME_HS6:=2496000}"
: "${GAME_LOAD6:=80}"
: "${GAME_RTG6:=1996800}"
: "${GAME_MIN6:=0}"
: "${GAME_DOWN_RATE:=8000}"
: "${GAME_UP_RATE:=0}"

# 省电档：仅限制 CPU 最高频率；GPU 和系统温控交给厂商
: "${ECO_MAX0:=2496000}"
: "${ECO_MAX6:=1996800}"
: "${ECO_MIN0:=787200}"
: "${ECO_MIN6:=883200}"
: "${ECO_HS0:=1555200}"
: "${ECO_HS6:=1804800}"
: "${ECO_LOAD:=92}"
: "${ECO_UCLAMP:=0}"
: "${GAME_PATTERNS:=com.tencent.tmgp.* com.tencent.ig* com.tencent.*.game* com.miHoYo.* com.mihoyo.* com.hoyoverse.* com.netease.* com.hypergryph.* com.papegames.* com.yostar.* com.bilibili.game* com.bilibili.sy* com.ztgame.* com.qookkagames.* com.supercell.* com.roblox.* com.mojang.* com.epicgames.* com.activision.* com.ea.* com.gameloft.* com.netmarble.* com.krafton.* com.pubg.* com.garena.* com.dts.freefire* com.innersloth.* com.tgc.sky.* com.sega.* com.capcom.* com.bandainamcoent.* com.square_enix.* jp.konami.* com.king.* com.zynga.* com.playdemic.* com.scopely.* com.hermes.* com.youzu.* com.eyougame.*}"

# 安全配置解析：只接受白名单 KEY=value，不执行配置文件中的 Shell 代码。
# 支持简单双引号；不支持变量展开/命令替换/行尾注释。
trim_ws() {
    _tw=$1
    while :; do
        case "$_tw" in
            ' '*|"	"*) _tw=${_tw#?} ;;
            *) break ;;
        esac
    done
    while :; do
        case "$_tw" in
            *' '|*"	") _tw=${_tw%?} ;;
            *) break ;;
        esac
    done
    printf '%s' "$_tw"
}

load_config() {
    _cfg="$DATADIR/config.sh"
    [ -f "$_cfg" ] && [ ! -L "$_cfg" ] || return 0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in ''|'#'*) continue ;; esac
        case "$_line" in *=*) ;; *) continue ;; esac
        _key=$(trim_ws "${_line%%=*}")
        _val=$(trim_ws "${_line#*=}")
        case "$_val" in
            \"*\") _val=${_val#\"}; _val=${_val%\"} ;;
        esac
        case "$_key" in
            ON_HS0|ON_LOAD0|ON_RTG0|ON_MIN0|ON_HS6|ON_LOAD6|ON_RTG6|ON_MIN6|ON_DOWN_RATE|ON_UP_RATE|ON_MAX0|DISPLAY_UCLAMP|TOP_UCLAMP|GAME_UCLAMP|GAME_HS0|GAME_LOAD0|GAME_RTG0|GAME_MIN0|GAME_HS6|GAME_LOAD6|GAME_RTG6|GAME_MIN6|GAME_DOWN_RATE|GAME_UP_RATE|ECO_MAX0|ECO_MAX6|ECO_MIN0|ECO_MIN6|ECO_HS0|ECO_HS6|ECO_LOAD|ECO_UCLAMP)
                case "$_val" in ''|*[!0-9]*) continue ;; esac
                ;;
        esac
        case "$_key" in
            ON_HS0) ON_HS0=$_val ;; ON_LOAD0) ON_LOAD0=$_val ;; ON_RTG0) ON_RTG0=$_val ;;
            ON_MIN0) ON_MIN0=$_val ;; ON_HS6) ON_HS6=$_val ;; ON_LOAD6) ON_LOAD6=$_val ;;
            ON_RTG6) ON_RTG6=$_val ;; ON_MIN6) ON_MIN6=$_val ;; ON_DOWN_RATE) ON_DOWN_RATE=$_val ;;
            ON_UP_RATE) ON_UP_RATE=$_val ;;
            ON_MAX0) ON_MAX0=$_val ;; DISPLAY_UCLAMP) DISPLAY_UCLAMP=$_val ;; TOP_UCLAMP) TOP_UCLAMP=$_val ;;
            GAME_UCLAMP) GAME_UCLAMP=$_val ;; GAME_HS0) GAME_HS0=$_val ;; GAME_LOAD0) GAME_LOAD0=$_val ;;
            GAME_RTG0) GAME_RTG0=$_val ;; GAME_MIN0) GAME_MIN0=$_val ;; GAME_HS6) GAME_HS6=$_val ;;
            GAME_LOAD6) GAME_LOAD6=$_val ;; GAME_RTG6) GAME_RTG6=$_val ;; GAME_MIN6) GAME_MIN6=$_val ;;
            GAME_DOWN_RATE) GAME_DOWN_RATE=$_val ;; GAME_UP_RATE) GAME_UP_RATE=$_val ;;
            ECO_MAX0) ECO_MAX0=$_val ;; ECO_MAX6) ECO_MAX6=$_val ;;
            ECO_MIN0) ECO_MIN0=$_val ;; ECO_MIN6) ECO_MIN6=$_val ;; ECO_HS0) ECO_HS0=$_val ;;
            ECO_HS6) ECO_HS6=$_val ;; ECO_LOAD) ECO_LOAD=$_val ;; ECO_UCLAMP) ECO_UCLAMP=$_val ;;
            ON_HS_POLICY)
                case "$_val" in
                    raise|set) ON_HS_POLICY=$_val ;;
                    *) log "配置 ON_HS_POLICY 只接受 raise/set，忽略该项" ;;
                esac
                ;;
            GAME_PATTERNS)
                case "$_val" in
                    *[!A-Za-z0-9_.*\ -]*)
                        log "配置 GAME_PATTERNS 含非法字符，忽略该项"
                        ;;
                    *) GAME_PATTERNS=$_val ;;
                esac
                ;;
        esac
    done < "$_cfg"
}
load_config

validate_config() {
    _vc_k=
    for _vc_k in ON_LOAD0 ON_LOAD6 GAME_LOAD0 GAME_LOAD6 ECO_LOAD; do
        eval "_vc_v=\${$_vc_k}"
        case "$_vc_v" in ''|*[!0-9]*) _vc_v=80 ;; esac
        [ "$_vc_v" -ge 1 ] 2>/dev/null && [ "$_vc_v" -le 100 ] 2>/dev/null || _vc_v=80
        eval "$_vc_k=\$_vc_v"
    done
    for _vc_k in GAME_UCLAMP DISPLAY_UCLAMP TOP_UCLAMP ECO_UCLAMP; do
        eval "_vc_v=\${$_vc_k}"
        case "$_vc_v" in ''|*[!0-9]*) _vc_v=0 ;; esac
        [ "$_vc_v" -ge 0 ] 2>/dev/null && [ "$_vc_v" -le 100 ] 2>/dev/null || _vc_v=0
        eval "$_vc_k=\$_vc_v"
    done
    for _vc_k in ON_DOWN_RATE GAME_DOWN_RATE ON_UP_RATE GAME_UP_RATE; do
        eval "_vc_v=\${$_vc_k}"
        case "$_vc_v" in ''|*[!0-9]*) _vc_v=0 ;; esac
        [ "$_vc_v" -le 1000000 ] 2>/dev/null || _vc_v=0
        eval "$_vc_k=\$_vc_v"
    done
    # 频率单位 kHz；拒绝畸形或明显越界的用户覆盖值。
    for _vc_k in ON_HS0 ON_RTG0 ON_MIN0 ON_HS6 ON_RTG6 ON_MIN6 ON_MAX0 \
                 GAME_HS0 GAME_RTG0 GAME_MIN0 GAME_HS6 GAME_RTG6 GAME_MIN6 \
                 ECO_MAX0 ECO_MAX6 ECO_MIN0 ECO_MIN6 ECO_HS0 ECO_HS6; do
        eval "_vc_v=\${$_vc_k}"
        case "$_vc_v" in ''|*[!0-9]*) _vc_v=0 ;; esac
        [ "$_vc_v" -le 10000000 ] 2>/dev/null || _vc_v=0
        eval "$_vc_k=\$_vc_v"
    done
}
validate_config

# ---------- 快照记录（纯 Shell，无 awk/sed 子进程） ----------
record_applied() {
    _ra_f=$1
    _ra_v=$2
    [ -n "$_ra_f" ] && [ -n "$_ra_v" ] || return 0
    _ra_tmp="$APPLIED.tmp.$$"
    : > "$_ra_tmp" 2>/dev/null || return 1
    if [ -f "$APPLIED" ]; then
        while IFS= read -r _ra_line; do
            [ -n "$_ra_line" ] || continue
            [ "${_ra_line%% *}" = "$_ra_f" ] && continue
            printf '%s\n' "$_ra_line" >> "$_ra_tmp" || {
                rm -f "$_ra_tmp" 2>/dev/null
                return 1
            }
        done < "$APPLIED"
    fi
    printf '%s %s\n' "$_ra_f" "$_ra_v" >> "$_ra_tmp" || {
        rm -f "$_ra_tmp" 2>/dev/null
        return 1
    }
    mv -f "$_ra_tmp" "$APPLIED" 2>/dev/null || {
        rm -f "$_ra_tmp" 2>/dev/null
        return 1
    }
    [ "$(applied_of "$_ra_f")" = "$_ra_v" ] || return 1
    return 0
}

applied_of() {
    _ao_f=$1
    [ -n "$_ao_f" ] && [ -f "$APPLIED" ] || return 0
    while IFS= read -r _ao_line; do
        case "$_ao_line" in
            "$_ao_f "*) printf '%s\n' "${_ao_line#* }"; return 0 ;;
        esac
    done < "$APPLIED"
}

forget_applied() {
    _fa_f=$1
    [ -n "$_fa_f" ] && [ -f "$APPLIED" ] || return 0
    _fa_tmp="$APPLIED.tmp.$$"
    : > "$_fa_tmp" 2>/dev/null || return 1
    while IFS= read -r _fa_line; do
        [ -n "$_fa_line" ] || continue
        [ "${_fa_line%% *}" = "$_fa_f" ] && continue
        printf '%s\n' "$_fa_line" >> "$_fa_tmp" || {
            rm -f "$_fa_tmp" 2>/dev/null
            return 1
        }
    done < "$APPLIED"
    mv -f "$_fa_tmp" "$APPLIED" 2>/dev/null || {
        rm -f "$_fa_tmp" 2>/dev/null
        return 1
    }
    [ -z "$(applied_of "$_fa_f")" ]
}

def_of() {
    _do_f=$1
    [ -n "$_do_f" ] && [ -f "$DEF" ] || return 0
    while IFS= read -r _do_line; do
        case "$_do_line" in
            "$_do_f "*) printf '%s\n' "${_do_line#* }"; return 0 ;;
        esac
    done < "$DEF"
}

capture() {
    _ca_f=$1
    [ -e "$_ca_f" ] || return 0
    [ -n "$(def_of "$_ca_f")" ] && return 0

    _ca_v=$(read_node "$_ca_f" 2>/dev/null) || {
        log "无法读取原始值，禁止后续写入: $_ca_f"
        return 1
    }
    [ -n "$_ca_v" ] || {
        log "原始值为空，禁止后续写入: $_ca_f"
        return 1
    }

    _ca_tmp="$DEF.tmp.$$"
    : > "$_ca_tmp" 2>/dev/null || {
        log "无法创建原始值快照临时文件，禁止后续写入: $_ca_f"
        return 1
    }
    if [ -f "$DEF" ]; then
        while IFS= read -r _ca_line; do
            [ -n "$_ca_line" ] || continue
            printf '%s\n' "$_ca_line" >> "$_ca_tmp" || {
                rm -f "$_ca_tmp" 2>/dev/null
                log "复制已有原始值快照失败，禁止后续写入: $_ca_f"
                return 1
            }
        done < "$DEF"
    fi
    printf '%s %s\n' "$_ca_f" "$_ca_v" >> "$_ca_tmp" || {
        rm -f "$_ca_tmp" 2>/dev/null
        log "原始值快照写入失败，禁止后续写入: $_ca_f"
        return 1
    }
    mv -f "$_ca_tmp" "$DEF" 2>/dev/null || {
        rm -f "$_ca_tmp" 2>/dev/null
        log "原始值快照提交失败，禁止后续写入: $_ca_f"
        return 1
    }

    [ "$(def_of "$_ca_f")" = "$_ca_v" ] || {
        log "原始值快照校验失败，禁止后续写入: $_ca_f"
        return 1
    }
    return 0
}

capture_all() {
    _ca_failed=0
    for _ca_p in $PROFILE_PATHS; do
        [ -n "$_ca_p" ] || continue
        capture "$_ca_p" || _ca_failed=1
    done
    return "$_ca_failed"
}

# 只允许修改本模块明确管理的 WALT / CPU limit / uclamp 节点。
is_managed_path() {
    _imp_path=$1
    for _imp_item in $PROFILE_PATHS; do
        [ -n "$_imp_item" ] || continue
        [ "$_imp_item" = "$_imp_path" ] && return 0
    done
    return 1
}

# 每次写入前确保已保存当前启动周期的原始值。
ensure_baseline() {
    _eb_path=$1
    is_managed_path "$_eb_path" || {
        log "拒绝写入非白名单节点: $_eb_path"
        return 1
    }
    [ -e "$_eb_path" ] && [ -r "$_eb_path" ] && [ -w "$_eb_path" ] || {
        log "节点不存在、不可读或不可写，跳过: $_eb_path"
        return 1
    }
    [ -n "$(def_of "$_eb_path")" ] || capture "$_eb_path" || return 1
    [ -n "$(def_of "$_eb_path")" ] || return 1
    return 0
}

# 恢复记录无法落盘时，只在读回值仍等于本次写入值时立即回滚。
# 若读回值已被其它模块改变，则不覆盖外部值。
rollback_untracked_write() {
    _ru_path=$1
    _ru_written=$2
    _ru_original=$3
    [ -n "$_ru_written" ] && [ -n "$_ru_original" ] || {
        log "无法确认未登记写入的归属，需人工检查: $_ru_path"
        return 1
    }
    _ru_current=$(read_node "$_ru_path" 2>/dev/null) || _ru_current=
    if [ "$_ru_current" = "$_ru_written" ]; then
        if printf '%s\n' "$_ru_original" > "$_ru_path" 2>/dev/null \
           && [ "$(read_node "$_ru_path" 2>/dev/null)" = "$_ru_original" ]; then
            log "恢复记录失败后已立即回滚 $_ru_path"
            return 0
        fi
        log "恢复记录失败且立即回滚失败: $_ru_path"
        return 1
    fi
    log "恢复记录失败；当前值已变化，不覆盖外部修改: $_ru_path"
    return 1
}

# 仅接受本模块管理节点能够出现的数值格式，防止损坏的状态文件触发任意写入。
valid_managed_value() {
    _vm_path=$1
    _vm_value=$2
    [ -n "$_vm_value" ] || return 1

    case "$_vm_path" in
        */cpu.uclamp.min)
            case "$_vm_value" in
                *[!0-9.]*|.*|*.) return 1 ;;
                *.*.*) return 1 ;;
            esac
            _vm_whole=${_vm_value%%.*}
            _vm_frac=
            case "$_vm_value" in
                *.*) _vm_frac=${_vm_value#*.} ;;
            esac
            case "$_vm_whole" in ''|*[!0-9]*) return 1 ;; esac
            case "$_vm_frac" in ''|*[!0-9]*) [ -z "$_vm_frac" ] || return 1 ;; esac
            [ "$_vm_whole" -le 100 ] 2>/dev/null || return 1
            if [ "$_vm_whole" -eq 100 ] 2>/dev/null && [ -n "$_vm_frac" ]; then
                case "$_vm_frac" in *[!0]*) return 1 ;; esac
            fi
            return 0
            ;;
        *)
            case "$_vm_value" in ''|*[!0-9]*) return 1 ;; esac
            return 0
            ;;
    esac
}

# 只统计归属记录与当前值不一致的节点；该检查只读，不触发任何修复写入。
ownership_conflict_count() {
    [ -f "$APPLIED" ] || { printf '0\n'; return 0; }
    _oc_count=0
    while IFS= read -r _oc_line; do
        [ -n "$_oc_line" ] || continue
        _oc_path=${_oc_line%% *}
        _oc_last=${_oc_line#* }
        if [ "$_oc_path" = "$_oc_line" ] || ! is_managed_path "$_oc_path"; then
            _oc_count=$((_oc_count + 1))
            continue
        fi
        _oc_current=$(read_node "$_oc_path" 2>/dev/null) || _oc_current=
        [ "$_oc_current" = "$_oc_last" ] || _oc_count=$((_oc_count + 1))
    done < "$APPLIED"
    printf '%s\n' "$_oc_count"
}

# ---------- 写入 ----------
# 回滚语义：只有“当前值仍等于本模块最后写入值”时才恢复，绝不覆盖外部新值。
restore_one_if_owned() {
    _rf_f=$1
    _rf_last=$(applied_of "$_rf_f")
    [ -n "$_rf_last" ] || return 0
    is_managed_path "$_rf_f" || {
        log "拒绝恢复非白名单节点 $_rf_f；保留恢复记录供检查"
        return 1
    }
    valid_managed_value "$_rf_f" "$_rf_last" || {
        log "恢复记录格式异常 $_rf_f；拒绝写入并保留记录"
        return 1
    }
    [ -e "$_rf_f" ] || { log "恢复节点暂不可用 $_rf_f；保留恢复记录"; return 1; }
    _rf_cur=$(read_node "$_rf_f" 2>/dev/null) || _rf_cur=
    _rf_def=$(def_of "$_rf_f")
    valid_managed_value "$_rf_f" "$_rf_def" || {
        log "原始快照格式异常 $_rf_f；拒绝恢复并保留记录"
        return 1
    }
    if [ "$_rf_cur" = "$_rf_last" ]; then
        if printf '%s\n' "$_rf_def" > "$_rf_f" 2>/dev/null && [ "$(read_node "$_rf_f" 2>/dev/null)" = "$_rf_def" ]; then
            log "恢复 $_rf_f = $_rf_def"
            forget_applied "$_rf_f"
            return 0
        fi
        log "恢复失败 $_rf_f（目标 $_rf_def），保留恢复记录"
        return 1
    elif [ -n "$_rf_cur" ] && [ "$_rf_cur" != "$_rf_last" ]; then
        log "保留外部修改 $_rf_f = $_rf_cur（模块最后写入 $_rf_last）"
        forget_applied "$_rf_f"
        return 0
    fi
    log "缺少 $_rf_f 的原始快照或当前值不可读，无法安全恢复；保留记录"
    return 1
}

restore_owned_paths() {
    for _rp_p in $1; do restore_one_if_owned "$_rp_p"; done
}

set_val() {
    _sv_f=$1
    _sv_v=$2
    [ -n "$_sv_v" ] || return 0

    is_managed_path "$_sv_f" || {
        log "拒绝写入非白名单节点: $_sv_f"
        SF_WRITE_FAILED=1
        return 1
    }
    valid_managed_value "$_sv_f" "$_sv_v" || {
        log "拒绝格式异常的目标值: $_sv_f=$_sv_v"
        SF_WRITE_FAILED=1
        return 1
    }

    _sv_cur=$(read_node "$_sv_f" 2>/dev/null) || _sv_cur=
    [ -n "$_sv_cur" ] || {
        log "节点当前值不可读，跳过写入: $_sv_f"
        SF_WRITE_FAILED=1
        return 1
    }
    [ "$_sv_cur" = "$_sv_v" ] && return 0

    ensure_baseline "$_sv_f" || {
        SF_WRITE_FAILED=1
        return 1
    }
    _sv_def=$(def_of "$_sv_f")
    _sv_last=$(applied_of "$_sv_f")
    if [ -n "$_sv_last" ]; then
        if [ "$_sv_cur" != "$_sv_last" ]; then
            case " $_sf_conflicted_paths " in
                *" $_sv_f "*) ;;
                *)
                    _sf_conflicted_paths="$_sf_conflicted_paths $_sv_f "
                    log "检测到外部节点占用，跳过写入 $_sv_f（当前=$_sv_cur，SmoothFlow 最后写入=$_sv_last）"
                    ;;
            esac
            SF_WRITE_CONFLICT=1
            return 0
        fi
    elif [ "$_sv_cur" != "$_sv_def" ]; then
        case " $_sf_conflicted_paths " in
            *" $_sv_f "*) ;;
            *)
                _sf_conflicted_paths="$_sf_conflicted_paths $_sv_f "
                log "节点在基线采集后发生变化，跳过写入 $_sv_f（当前=$_sv_cur，基线=$_sv_def）"
                ;;
        esac
        SF_WRITE_CONFLICT=1
        return 0
    fi

    if printf '%s\n' "$_sv_v" > "$_sv_f" 2>/dev/null; then
        _sv_after=$(read_node "$_sv_f" 2>/dev/null) || _sv_after=
        if [ "$_sv_after" = "$_sv_v" ]; then
            if record_applied "$_sv_f" "$_sv_v"; then
                log "写入 $_sv_f = $_sv_v (原 $_sv_cur)"
            else
                log "恢复记录写入失败：$_sv_f；尝试立即回滚"
                rollback_untracked_write "$_sv_f" "$_sv_after" "$_sv_cur" || :
                SF_WRITE_FAILED=1
            fi
        elif [ -n "$_sv_after" ] && [ "$_sv_after" != "$_sv_cur" ]; then
            if record_applied "$_sv_f" "$_sv_after"; then
                log "写入值被内核调整 $_sv_f：请求=$_sv_v 实际=$_sv_after（已记录实际值用于恢复）"
            else
                log "恢复记录写入失败：$_sv_f；尝试立即回滚"
                rollback_untracked_write "$_sv_f" "$_sv_after" "$_sv_cur" || :
            fi
            SF_WRITE_FAILED=1
        else
            log "写入后校验不一致 $_sv_f：目标=$_sv_v 实际=${_sv_after:-空值}"
            SF_WRITE_FAILED=1
        fi
    else
        log "写入失败 $_sv_f = $_sv_v (当前 $_sv_cur)"
        SF_WRITE_FAILED=1
    fi
}

# 规范化 uclamp 百分比：10、10.0、10.00 视为相等，但 10.50 不等于 10。
# 全程使用 Shell 内建，避免在守护进程热路径引入 awk/bc 子进程。
normalize_pct() {
    _np_value=$1
    case "$_np_value" in
        ''|*[!0-9.]*|.*|*.) return 1 ;;
        *.*.*) return 1 ;;
    esac
    _np_whole=${_np_value%%.*}
    _np_frac=
    case "$_np_value" in
        *.*) _np_frac=${_np_value#*.} ;;
    esac
    case "$_np_whole" in ''|*[!0-9]*) return 1 ;; esac
    case "$_np_frac" in *[!0-9]*) return 1 ;; esac
    while :; do
        case "$_np_frac" in
            *0) _np_frac=${_np_frac%?} ;;
            *) break ;;
        esac
    done
    if [ -n "$_np_frac" ]; then
        printf '%s.%s\n' "$_np_whole" "$_np_frac"
    else
        printf '%s\n' "$_np_whole"
    fi
}

pct_matches() {
    _pm_left=$(normalize_pct "$1") || return 1
    _pm_right=$(normalize_pct "$2") || return 1
    [ "$_pm_left" = "$_pm_right" ]
}

# uclamp 为百分比；按规范化后的完整小数值比较，避免 10.50 被误判为 10。
set_pct() {
    _sp_path=$1
    _sp_value=$2
    case "$_sp_value" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_sp_value" -le 100 ] 2>/dev/null || { log "uclamp 越界，跳过: $_sp_path=$_sp_value"; return 0; }

    is_managed_path "$_sp_path" || {
        log "拒绝写入非白名单 uclamp 节点: $_sp_path"
        SF_WRITE_FAILED=1
        return 1
    }
    _sp_cur=$(read_node "$_sp_path" 2>/dev/null) || _sp_cur=
    [ -n "$_sp_cur" ] || {
        log "uclamp 当前值不可读，跳过写入: $_sp_path"
        SF_WRITE_FAILED=1
        return 1
    }
    pct_matches "$_sp_cur" "$_sp_value" && return 0

    ensure_baseline "$_sp_path" || {
        SF_WRITE_FAILED=1
        return 1
    }
    _sp_def=$(def_of "$_sp_path")
    _sp_last=$(applied_of "$_sp_path")
    if [ -n "$_sp_last" ]; then
        if [ "$_sp_cur" != "$_sp_last" ]; then
            case " $_sf_conflicted_paths " in
                *" $_sp_path "*) ;;
                *)
                    _sf_conflicted_paths="$_sf_conflicted_paths $_sp_path "
                    log "检测到外部 uclamp 节点占用，跳过写入 $_sp_path（当前=$_sp_cur，SmoothFlow 最后写入=$_sp_last）"
                    ;;
            esac
            SF_WRITE_CONFLICT=1
            return 0
        fi
    elif [ "$_sp_cur" != "$_sp_def" ]; then
        case " $_sf_conflicted_paths " in
            *" $_sp_path "*) ;;
            *)
                _sf_conflicted_paths="$_sf_conflicted_paths $_sp_path "
                log "uclamp 在基线采集后发生变化，跳过写入 $_sp_path（当前=$_sp_cur，基线=$_sp_def）"
                ;;
        esac
        SF_WRITE_CONFLICT=1
        return 0
    fi

    if printf '%s.00\n' "$_sp_value" > "$_sp_path" 2>/dev/null; then
        _sp_after=$(read_node "$_sp_path" 2>/dev/null) || _sp_after=
        _sp_after_i=${_sp_after%%.*}
        case "$_sp_after_i" in ''|*[!0-9]*) _sp_after_i=-1 ;; esac
        if [ "$_sp_after_i" = "$_sp_value" ]; then
            if record_applied "$_sp_path" "$_sp_after"; then
                log "写入 $_sp_path = $_sp_after (原 $_sp_cur)"
            else
                log "uclamp 恢复记录写入失败，尝试立即回滚: $_sp_path"
                rollback_untracked_write "$_sp_path" "$_sp_after" "$_sp_cur" || :
                SF_WRITE_FAILED=1
            fi
        else
            log "uclamp 写入校验失败 $_sp_path：目标=$_sp_value 实际=${_sp_after:-空值}"
            SF_WRITE_FAILED=1
        fi
    else
        log "写入失败 $_sp_path = $_sp_value (当前 $_sp_cur)"
        SF_WRITE_FAILED=1
    fi
}

# 把请求频率对齐到内核实际支持的频率表：
#   up   = 不小于请求值的最小可用频率（升频目标 / 最低频率）
#   down = 不大于请求值的最大可用频率（频率上限）
# 内核频率表随 OTA / 机型批次变化，硬编码值可能整组失效；对齐后不改变调参意图。
snap_freq() {
    _sn_list=$(read_node "$1/scaling_available_frequencies" 2>/dev/null) || return 1
    _sn_val=$2
    _sn_mode=$3
    _sn_best=
    _sn_dist=
    for _sn_f in $_sn_list; do
        case "$_sn_f" in ''|*[!0-9]*) continue ;; esac
        case "$_sn_mode" in
            down)
                [ "$_sn_f" -le "$_sn_val" ] || continue
                [ -z "$_sn_best" ] || [ "$_sn_f" -gt "$_sn_best" ] && _sn_best=$_sn_f
                ;;
            up)
                [ "$_sn_f" -ge "$_sn_val" ] || continue
                [ -z "$_sn_best" ] || [ "$_sn_f" -lt "$_sn_best" ] && _sn_best=$_sn_f
                ;;
            *)
                # 绝对值最近；距离相同取更高的频率，避免削弱升频目标
                if [ "$_sn_f" -ge "$_sn_val" ]; then _sn_d=$((_sn_f - _sn_val)); else _sn_d=$((_sn_val - _sn_f)); fi
                if [ -z "$_sn_dist" ] || [ "$_sn_d" -lt "$_sn_dist" ] \
                   || { [ "$_sn_d" -eq "$_sn_dist" ] && [ "$_sn_f" -gt "$_sn_best" ]; }; then
                    _sn_dist=$_sn_d
                    _sn_best=$_sn_f
                fi
                ;;
        esac
    done
    [ -n "$_sn_best" ] || return 1
    printf '%s\n' "$_sn_best"
}

valid_freq() {
    case " $(read_node "$1/scaling_available_frequencies" 2>/dev/null) " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

set_freq() {
    # $1 节点  $2 请求频率  $3 policy 目录  $4 near|up|down
    _sf_mode=${4:-up}
    _sf_val=$(snap_freq "$3" "$2" "$_sf_mode") || {
        log "频率 $2 无法对齐到 $3 的支持列表，跳过"
        return 0
    }
    if [ "$_sf_val" != "$2" ]; then
        log "频率 $2 不在 $3 支持列表内，改用最接近的 $_sf_val"
    fi
    set_val "$1" "$_sf_val"
}

# ---------- 档位应用 ----------
raise_min() {
    _rm_f=$1
    _rm_v=$2
    _rm_pol=
    case "$_rm_f" in
        "$CPU0/scaling_min_freq") _rm_pol=$CPU0 ;;
        "$CPU6/scaling_min_freq") _rm_pol=$CPU6 ;;
        *) return 0 ;;
    esac
    [ "$_rm_v" -gt 0 ] 2>/dev/null || return 0
    _rm_v=$(snap_freq "$_rm_pol" "$_rm_v" up) || { log "最低频率无法对齐到 $_rm_pol 的支持列表，跳过"; return 0; }
    _rm_max=$(read_node "$_rm_pol/scaling_max_freq" 2>/dev/null)
    if [ -n "$_rm_max" ] && [ "$_rm_v" -gt "$_rm_max" ] 2>/dev/null; then
        log "最低频率 $_rm_v 高于当前上限 $_rm_max，跳过"
        return 0
    fi
    _rm_cur=$(read_node "$_rm_f" 2>/dev/null)
    [ -n "$_rm_cur" ] || return 0
    if [ "$_rm_cur" -lt "$_rm_v" ] 2>/dev/null; then
        set_val "$_rm_f" "$_rm_v"
    fi
}

cap_max() {
    _cm_f=$1
    _cm_v=$2
    _cm_pol=
    case "$_cm_f" in
        "$CPU0/scaling_max_freq") _cm_pol=$CPU0 ;;
        "$CPU6/scaling_max_freq") _cm_pol=$CPU6 ;;
        *) return 0 ;;
    esac
    [ "$_cm_v" -gt 0 ] 2>/dev/null || return 0
    _cm_v=$(snap_freq "$_cm_pol" "$_cm_v" down) || { log "频率上限无法对齐到 $_cm_pol 的支持列表，跳过"; return 0; }
    _cm_cur=$(read_node "$_cm_f" 2>/dev/null)
    [ -n "$_cm_cur" ] || return 0
    _cm_min=$(read_node "$_cm_pol/scaling_min_freq" 2>/dev/null)
    if [ -n "$_cm_min" ] && [ "$_cm_v" -lt "$_cm_min" ] 2>/dev/null; then
        log "上限 $_cm_v 低于当前最低频率 $_cm_min，跳过以避免 min/max 冲突"
        return 0
    fi
    if [ "$_cm_cur" -gt "$_cm_v" ] 2>/dev/null; then
        set_val "$_cm_f" "$_cm_v"
    fi
}

# 仅当当前值正好是游戏档写进去的值时才降回；目标为 0 时回落到原厂快照，
# 避免向 scaling_min_freq 写入非法值 0。
lower_ours() {
    _lo_cur=$(read_node "$1" 2>/dev/null)
    [ -n "$_lo_cur" ] || return 0
    [ "$_lo_cur" = "$3" ] || return 0
    if [ "$2" -gt 0 ] 2>/dev/null; then
        set_val "$1" "$2"
    else
        _lo_def=$(def_of "$1")
        [ -n "$_lo_def" ] && set_val "$1" "$_lo_def"
    fi
}

# 撤销本模块写入的省电上限：不做“当前值必须等于配置值”的精确匹配，
# 交由 restore_one_if_owned 处理内核钳位/外部改写。
restore_eco_caps() {
    # 频率表可能与配置值不同，写入的是 snap 之后的值；这里必须用同样的对齐结果判定归属，
    # 否则省电上限会残留（例如配置 1996800、实际写入 1977600）。
    _re_cap=$(snap_freq "$CPU0" "$ECO_MAX0" down) || _re_cap=
    if [ -n "$_re_cap" ] && [ "$(applied_of "$CPU0/scaling_max_freq")" = "$_re_cap" ]; then
        restore_one_if_owned "$CPU0/scaling_max_freq"
    fi
    _re_cap=$(snap_freq "$CPU6" "$ECO_MAX6" down) || _re_cap=
    if [ -n "$_re_cap" ] && [ "$(applied_of "$CPU6/scaling_max_freq")" = "$_re_cap" ]; then
        restore_one_if_owned "$CPU6/scaling_max_freq"
    fi
}

# 退出游戏 / 进入省电档时，把"我们抬起来的最低频率"放回原厂值。
# 比对基准必须是 snap 后的实际写入值，不能用原始配置值。
settle_min() {
    _st_file=$1
    _st_pol=$2
    _st_target=$3
    shift 3
    for _st_raw in "$@"; do
        [ "$_st_raw" -gt 0 ] 2>/dev/null || continue
        _st_ours=$(snap_freq "$_st_pol" "$_st_raw" up) || continue
        lower_ours "$_st_file" "$_st_target" "$_st_ours"
    done
}

apply_on() {
    if ! device_ok; then
        log "设备身份/CPU 拓扑/WALT 必需节点未通过安全检查，拒绝写入日常档"
        return 2
    fi
    lock_profile || return 1
    SF_WRITE_FAILED=0
    SF_WRITE_CONFLICT=0
    _sf_conflicted_paths=
    capture_all >/dev/null 2>&1 || log "部分节点预采集未完成；逐节点写入前仍会强制检查原始快照"
    restore_eco_caps
    reassert_on
    [ -n "$DISPLAY_UCLAMP_PATH" ] && set_pct "$DISPLAY_UCLAMP_PATH" "$DISPLAY_UCLAMP"
    if [ "$TOP_UCLAMP" != "0" ] 2>/dev/null; then
        [ -n "$TOP_APP_UCLAMP_PATH" ] && set_pct "$TOP_APP_UCLAMP_PATH" "$TOP_UCLAMP"
    else
        [ -n "$TOP_APP_UCLAMP_PATH" ] && restore_one_if_owned "$TOP_APP_UCLAMP_PATH"
    fi
    cap_max "$CPU0/scaling_max_freq" "$ON_MAX0"
    # 退出游戏后把游戏档抬起来的最低频率降回日常档（只降我们自己设过的值）
    settle_min "$CPU0/scaling_min_freq" "$CPU0" "$ON_MIN0" "$GAME_MIN0"
    settle_min "$CPU6/scaling_min_freq" "$CPU6" "$ON_MIN6" "$GAME_MIN6"
    [ "${SF_WRITE_CONFLICT:-0}" = 1 ] && log "档位已应用，但存在外部节点占用；冲突节点已跳过写入"
    unlock_profile
    [ "${SF_WRITE_FAILED:-0}" = 0 ]
}

apply_game() {
    if ! device_ok; then
        log "设备身份/CPU 拓扑/WALT 必需节点未通过安全检查，拒绝写入游戏档"
        return 2
    fi
    lock_profile || return 1
    SF_WRITE_FAILED=0
    SF_WRITE_CONFLICT=0
    _sf_conflicted_paths=
    capture_all >/dev/null 2>&1 || log "部分节点预采集未完成；逐节点写入前仍会强制检查原始快照"
    restore_eco_caps
    set_freq "$W0/hispeed_freq"  "$GAME_HS0"  "$CPU0"
    set_val  "$W0/hispeed_load"  "$GAME_LOAD0"
    set_freq "$W0/rtg_boost_freq" "$GAME_RTG0" "$CPU0"
    raise_min "$CPU0/scaling_min_freq" "$GAME_MIN0"
    set_freq "$W6/hispeed_freq"  "$GAME_HS6"  "$CPU6"
    set_val  "$W6/hispeed_load"  "$GAME_LOAD6"
    set_freq "$W6/rtg_boost_freq" "$GAME_RTG6" "$CPU6"
    set_val  "$W0/down_rate_limit_us" "$GAME_DOWN_RATE"
    set_val  "$W6/down_rate_limit_us" "$GAME_DOWN_RATE"
    if [ "$GAME_UP_RATE" -gt 0 ] 2>/dev/null; then
        if [ -e "$W0/up_rate_limit_us" ]; then set_val "$W0/up_rate_limit_us" "$GAME_UP_RATE"; else log "低簇 up_rate_limit 节点不存在，跳过可选项"; fi
        if [ -e "$W6/up_rate_limit_us" ]; then set_val "$W6/up_rate_limit_us" "$GAME_UP_RATE"; else log "高簇 up_rate_limit 节点不存在，跳过可选项"; fi
    fi
    raise_min "$CPU6/scaling_min_freq" "$GAME_MIN6"
    [ -n "$DISPLAY_UCLAMP_PATH" ] && set_pct "$DISPLAY_UCLAMP_PATH" "$DISPLAY_UCLAMP"
    if [ -n "$TOP_APP_UCLAMP_PATH" ]; then
        if [ "$TOP_UCLAMP" != "0" ] 2>/dev/null; then
            set_pct "$TOP_APP_UCLAMP_PATH" "$TOP_UCLAMP"
        else
            set_pct "$TOP_APP_UCLAMP_PATH" "$GAME_UCLAMP"
        fi
    fi
    [ "${SF_WRITE_CONFLICT:-0}" = 1 ] && log "档位已应用，但存在外部节点占用；冲突节点已跳过写入"
    unlock_profile
    [ "${SF_WRITE_FAILED:-0}" = 0 ]
}

apply_eco() {
    if ! device_ok; then
        log "设备身份/CPU 拓扑/WALT 必需节点未通过安全检查，拒绝写入省电档"
        return 2
    fi
    lock_profile || return 1
    SF_WRITE_FAILED=0
    SF_WRITE_CONFLICT=0
    _sf_conflicted_paths=
    capture_all >/dev/null 2>&1 || log "部分节点预采集未完成；逐节点写入前仍会强制检查原始快照"
    set_freq "$W0/hispeed_freq" "$ECO_HS0" "$CPU0"
    set_val "$W0/hispeed_load" "$ECO_LOAD"
    set_freq "$W0/rtg_boost_freq" "$ON_RTG0" "$CPU0"
    set_val "$W0/down_rate_limit_us" "$ON_DOWN_RATE"
    set_freq "$W6/hispeed_freq" "$ECO_HS6" "$CPU6"
    set_val "$W6/hispeed_load" "$ECO_LOAD"
    set_freq "$W6/rtg_boost_freq" "$ON_RTG6" "$CPU6"
    set_val "$W6/down_rate_limit_us" "$ON_DOWN_RATE"
    if [ "$ON_UP_RATE" -gt 0 ] 2>/dev/null; then
        [ -e "$W0/up_rate_limit_us" ] && set_val "$W0/up_rate_limit_us" "$ON_UP_RATE"
        [ -e "$W6/up_rate_limit_us" ] && set_val "$W6/up_rate_limit_us" "$ON_UP_RATE"
    else
        restore_one_if_owned "$W0/up_rate_limit_us"
        restore_one_if_owned "$W6/up_rate_limit_us"
    fi
    settle_min "$CPU0/scaling_min_freq" "$CPU0" "$(def_of "$CPU0/scaling_min_freq")" "$ON_MIN0" "$GAME_MIN0"
    settle_min "$CPU6/scaling_min_freq" "$CPU6" "$(def_of "$CPU6/scaling_min_freq")" "$ON_MIN6" "$GAME_MIN6"
    cap_max "$CPU0/scaling_max_freq" "$ECO_MAX0"
    cap_max "$CPU6/scaling_max_freq" "$ECO_MAX6"
    [ -n "$DISPLAY_UCLAMP_PATH" ] && set_pct "$DISPLAY_UCLAMP_PATH" "$ECO_UCLAMP"
    [ -n "$TOP_APP_UCLAMP_PATH" ] && set_pct "$TOP_APP_UCLAMP_PATH" 0
    [ "${SF_WRITE_CONFLICT:-0}" = 1 ] && log "档位已应用，但存在外部节点占用；冲突节点已跳过写入"
    unlock_profile
    [ "${SF_WRITE_FAILED:-0}" = 0 ]
}

# 只升不降：当前值已经高于目标（厂商/其它模块给得更高）时不动它，
# 避免日常档把设备调得比原厂更保守。ON_HS_POLICY=set 可恢复旧的绝对写入语义。
raise_freq() {
    _rr_val=$(snap_freq "$3" "$2" up) || { log "频率 $2 无法对齐到 $3 的支持列表，跳过"; return 0; }
    _rr_cur=$(read_node "$1" 2>/dev/null) || return 0
    _rr_last=$(applied_of "$1")

    # 当前值若仍是本模块写入的游戏/省电档值，日常档必须先回到
    # max(原厂快照, 日常目标)，不能把自己的高值误当成厂商高值保留。
    if [ -n "$_rr_last" ] && [ "$_rr_cur" = "$_rr_last" ]; then
        _rr_base=$(def_of "$1")
        case "$_rr_base" in ''|*[!0-9]*) _rr_base= ;; esac
        if [ -n "$_rr_base" ] && [ "$_rr_base" -gt "$_rr_val" ] 2>/dev/null; then
            _rr_val=$_rr_base
        fi
        [ "$_rr_cur" = "$_rr_val" ] || set_val "$1" "$_rr_val"
        return 0
    fi

    # 非本模块拥有的当前值视为厂商/其它模块状态：只在低于目标时向上补齐。
    [ "$_rr_cur" -lt "$_rr_val" ] 2>/dev/null || return 0
    set_val "$1" "$_rr_val"
}

reassert_on() {
    if [ "$ON_HS_POLICY" = set ]; then
        set_freq "$W0/hispeed_freq"  "$ON_HS0"  "$CPU0"
        set_freq "$W0/rtg_boost_freq" "$ON_RTG0" "$CPU0"
        set_freq "$W6/hispeed_freq"  "$ON_HS6"  "$CPU6"
        set_freq "$W6/rtg_boost_freq" "$ON_RTG6" "$CPU6"
    else
        raise_freq "$W0/hispeed_freq"  "$ON_HS0"  "$CPU0"
        raise_freq "$W0/rtg_boost_freq" "$ON_RTG0" "$CPU0"
        raise_freq "$W6/hispeed_freq"  "$ON_HS6"  "$CPU6"
        raise_freq "$W6/rtg_boost_freq" "$ON_RTG6" "$CPU6"
    fi
    set_val  "$W0/hispeed_load"  "$ON_LOAD0"
    set_val  "$W0/down_rate_limit_us" "$ON_DOWN_RATE"
    if [ "$ON_UP_RATE" -gt 0 ] 2>/dev/null && [ -e "$W0/up_rate_limit_us" ]; then
        set_val "$W0/up_rate_limit_us" "$ON_UP_RATE"
    else
        restore_one_if_owned "$W0/up_rate_limit_us"
    fi
    raise_min "$CPU0/scaling_min_freq" "$ON_MIN0"
    set_val  "$W6/hispeed_load"  "$ON_LOAD6"
    set_val  "$W6/down_rate_limit_us" "$ON_DOWN_RATE"
    if [ "$ON_UP_RATE" -gt 0 ] 2>/dev/null && [ -e "$W6/up_rate_limit_us" ]; then
        set_val "$W6/up_rate_limit_us" "$ON_UP_RATE"
    else
        restore_one_if_owned "$W6/up_rate_limit_us"
    fi
    raise_min "$CPU6/scaling_min_freq" "$ON_MIN6"
}

# 漂移检测：只读比较 WALT 关键项，不把偏差直接认定为模块故障。
# 后续重新应用会经过 set_val 的归属门禁；发现外部修改时不会争抢写入权。
_drift_one() { # file expected policy low|eq
    if [ "$4" = eq ]; then
        _dr_e=$2
    else
        _dr_e=$(snap_freq "$3" "$2" up) || return 0
    fi
    _dr_c=$(read_node "$1" 2>/dev/null) || return 0
    if [ "$4" = eq ]; then
        [ "$_dr_c" = "$_dr_e" ] || return 1
    else
        [ "$_dr_c" -ge "$_dr_e" ] 2>/dev/null || return 1
    fi
    return 0
}

drift_detect() { # mode
    _dd_hs0=$ON_HS0; _dd_hs6=$ON_HS6; _dd_rtg0=$ON_RTG0; _dd_rtg6=$ON_RTG6
    _dd_load0=$ON_LOAD0; _dd_load6=$ON_LOAD6; _dd_down=$ON_DOWN_RATE
    if [ "$1" = game ]; then
        _dd_hs0=$GAME_HS0; _dd_hs6=$GAME_HS6; _dd_rtg0=$GAME_RTG0; _dd_rtg6=$GAME_RTG6
        _dd_load0=$GAME_LOAD0; _dd_load6=$GAME_LOAD6; _dd_down=$GAME_DOWN_RATE
    fi
    _dd_n=0
    _drift_one "$W0/hispeed_freq"    "$_dd_hs0"   "$CPU0" low || _dd_n=$((_dd_n + 1))
    _drift_one "$W6/hispeed_freq"    "$_dd_hs6"   "$CPU6" low || _dd_n=$((_dd_n + 1))
    _drift_one "$W0/rtg_boost_freq"  "$_dd_rtg0"  "$CPU0" low || _dd_n=$((_dd_n + 1))
    _drift_one "$W6/rtg_boost_freq"  "$_dd_rtg6"  "$CPU6" low || _dd_n=$((_dd_n + 1))
    _drift_one "$W0/hispeed_load"    "$_dd_load0" "" eq || _dd_n=$((_dd_n + 1))
    _drift_one "$W6/hispeed_load"    "$_dd_load6" "" eq || _dd_n=$((_dd_n + 1))
    _drift_one "$W0/down_rate_limit_us" "$_dd_down" "" eq || _dd_n=$((_dd_n + 1))
    _drift_one "$W6/down_rate_limit_us" "$_dd_down" "" eq || _dd_n=$((_dd_n + 1))
    if [ -n "$DISPLAY_UCLAMP_PATH" ]; then
        _dd_c=$(read_node "$DISPLAY_UCLAMP_PATH" 2>/dev/null) || _dd_c=
        _dd_want=$DISPLAY_UCLAMP
        [ "$1" = eco ] && _dd_want=$ECO_UCLAMP
        pct_matches "$_dd_c" "$_dd_want" || _dd_n=$((_dd_n + 1))
    fi
    printf '%s\n' "$_dd_n"
}

restore_all_locked() {
    [ -f "$APPLIED" ] || return 0
    cp "$APPLIED" "$APPLIED.restore" 2>/dev/null || return 1
    _rl_failed=0
    while IFS= read -r _rl_line; do
        _rl_p=${_rl_line%% *}
        [ -n "$_rl_p" ] || continue
        restore_one_if_owned "$_rl_p" || _rl_failed=1
    done < "$APPLIED.restore"
    rm -f "$APPLIED.restore" 2>/dev/null
    return "$_rl_failed"
}

apply_off() {
    lock_profile || return 1
    restore_all_locked
    _ro_rc=$?
    unlock_profile
    return "$_ro_rc"
}

restore_all() {
    lock_profile || return 1
    restore_all_locked
    _ra_rc=$?
    unlock_profile
    return "$_ra_rc"
}

# ---------- 参数写入互斥 ----------
PROFILE_LOCK=$DATADIR/profile.lock

# 纯 Shell 解析 /proc/<pid>/stat 的第 22 字段（starttime），不产生 sed/awk 子进程。
proc_start_time() {
    [ -r "$PROC/$1/stat" ] || return 1
    IFS= read -r _pst_line < "$PROC/$1/stat" 2>/dev/null || return 1
    _pst_rest=${_pst_line##*) }
    set -- $_pst_rest
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s\n' "$1"
}

lock_profile() {
    _lp_tries=0
    while [ "$_lp_tries" -lt 20 ]; do
        if mkdir "$PROFILE_LOCK" 2>/dev/null; then
            _lp_self_start=$(proc_start_time $$ 2>/dev/null) || _lp_self_start=
            if ! printf '%s %s\n' "$$" "$_lp_self_start" > "$PROFILE_LOCK/pid" 2>/dev/null; then
                rm -f "$PROFILE_LOCK/pid" 2>/dev/null
                rmdir "$PROFILE_LOCK" 2>/dev/null
                log "参数锁 PID 记录失败，拒绝本轮写入"
                return 1
            fi
            _lp_saved=$(read_node "$PROFILE_LOCK/pid" 2>/dev/null) || _lp_saved=
            if [ "${_lp_saved%% *}" != "$$" ]; then
                rm -f "$PROFILE_LOCK/pid" 2>/dev/null
                rmdir "$PROFILE_LOCK" 2>/dev/null
                log "参数锁归属校验失败，拒绝本轮写入"
                return 1
            fi
            return 0
        fi
        _lp_line=$(read_node "$PROFILE_LOCK/pid" 2>/dev/null) || _lp_line=
        _lp_owner=${_lp_line%% *}
        _lp_start=${_lp_line#* }
        [ "$_lp_start" = "$_lp_line" ] && _lp_start=
        case "$_lp_owner" in ''|*[!0-9]*) _lp_owner=0 ;; esac
        if [ "$_lp_owner" -gt 0 ] 2>/dev/null; then
            _lp_live=$(proc_start_time "$_lp_owner" 2>/dev/null) || _lp_live=
            if [ ! -d "$PROC/$_lp_owner" ] || { [ -n "$_lp_start" ] && [ -n "$_lp_live" ] && [ "$_lp_start" != "$_lp_live" ]; }; then
                rm -f "$PROFILE_LOCK/pid" 2>/dev/null
                rmdir "$PROFILE_LOCK" 2>/dev/null
            fi
        else
            # 只回收停在“mkdir 成功但 pid 还没写入”这一极小窗口的残锁，且需超过 30 秒。
            _lp_mtime=$(stat -c %Y "$PROFILE_LOCK" 2>/dev/null)
            _lp_now=$(date +%s 2>/dev/null)
            case "$_lp_mtime:$_lp_now" in *[!0-9:]*|:*) _lp_mtime=0 ;; esac
            if [ "$_lp_mtime" -gt 0 ] && [ $((_lp_now - _lp_mtime)) -gt 30 ] 2>/dev/null; then
                rmdir "$PROFILE_LOCK" 2>/dev/null
            fi
        fi
        sleep 0.2
        _lp_tries=$((_lp_tries + 1))
    done
    log "参数锁等待超时，跳过本轮档位写入"
    return 1
}

unlock_profile() {
    _up_line=$(read_node "$PROFILE_LOCK/pid" 2>/dev/null) || _up_line=
    if [ "${_up_line%% *}" = "$$" ]; then
        rm -f "$PROFILE_LOCK/pid" 2>/dev/null
        rmdir "$PROFILE_LOCK" 2>/dev/null
    fi
}

# ---------- 进程 ----------
pid_is_alive() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "$PROC/$1" ]
}

pid_is_ours() {
    _po_p=$1
    _po_kind=$2
    _po_expected_start=${3:-}
    pid_is_alive "$_po_p" || return 1
    if [ -n "$_po_expected_start" ]; then
        _po_live_start=$(proc_start_time "$_po_p" 2>/dev/null) || return 1
        [ "$_po_live_start" = "$_po_expected_start" ] || return 1
    fi
    _po_cmd=
    { IFS= read -r _po_cmd < "$PROC/$_po_p/cmdline"; } 2>/dev/null
    case "$_po_kind:$_po_cmd" in
        daemon:*smoothflow/bin/daemon.sh*|supervisor:*smoothflow/bin/supervisor.sh*) return 0 ;;
    esac
    return 1
}

daemon_alive() {
    [ -f "$PIDF" ] || return 1
    _da_line=$(read_node "$PIDF" 2>/dev/null) || return 1
    _da_p=${_da_line%% *}
    _da_start=${_da_line#* }
    [ "$_da_start" = "$_da_line" ] && _da_start=
    pid_is_ours "$_da_p" daemon "$_da_start"
}

supervisor_alive() {
    [ -f "$SUPIDF" ] || return 1
    _sa_line=$(read_node "$SUPIDF" 2>/dev/null) || return 1
    _sa_p=${_sa_line%% *}
    _sa_start=${_sa_line#* }
    [ "$_sa_start" = "$_sa_line" ] && _sa_start=
    pid_is_ours "$_sa_p" supervisor "$_sa_start"
}

# supervisor 使用独立目录锁，避免 service.sh 和手动 start 并发拉起多个实例。
acquire_supervisor_lock() {
    if mkdir "$SUPLOCK" 2>/dev/null; then
        _asl_start=$(proc_start_time $$ 2>/dev/null) || _asl_start=
        if ! printf '%s %s\n' "$$" "$_asl_start" > "$SUPLOCK/pid" 2>/dev/null; then
            rm -f "$SUPLOCK/pid" 2>/dev/null
            rmdir "$SUPLOCK" 2>/dev/null
            log "supervisor 锁记录失败，拒绝启动"
            return 1
        fi
        _asl_saved=$(read_node "$SUPLOCK/pid" 2>/dev/null) || _asl_saved=
        [ "${_asl_saved%% *}" = "$$" ] || {
            rm -f "$SUPLOCK/pid" 2>/dev/null
            rmdir "$SUPLOCK" 2>/dev/null
            log "supervisor 锁归属校验失败，拒绝启动"
            return 1
        }
        return 0
    fi

    _asl_line=$(read_node "$SUPLOCK/pid" 2>/dev/null) || _asl_line=
    _asl_pid=${_asl_line%% *}
    _asl_owner_start=${_asl_line#* }
    [ "$_asl_owner_start" = "$_asl_line" ] && _asl_owner_start=
    case "$_asl_pid" in ''|*[!0-9]*) _asl_pid=0 ;; esac

    if [ "$_asl_pid" -gt 0 ] 2>/dev/null; then
        _asl_live_start=$(proc_start_time "$_asl_pid" 2>/dev/null) || _asl_live_start=
        if [ ! -d "$PROC/$_asl_pid" ] || { [ -n "$_asl_owner_start" ] && [ -n "$_asl_live_start" ] && [ "$_asl_owner_start" != "$_asl_live_start" ]; }; then
            rm -f "$SUPLOCK/pid" 2>/dev/null
            rmdir "$SUPLOCK" 2>/dev/null
            mkdir "$SUPLOCK" 2>/dev/null || return 1
            _asl_start=$(proc_start_time $$ 2>/dev/null) || _asl_start=
            if ! printf '%s %s\n' "$$" "$_asl_start" > "$SUPLOCK/pid" 2>/dev/null; then
                rm -f "$SUPLOCK/pid" 2>/dev/null
                rmdir "$SUPLOCK" 2>/dev/null
                log "回收残留 supervisor 锁后写入 PID 失败，拒绝启动"
                return 1
            fi
            _asl_saved=$(read_node "$SUPLOCK/pid" 2>/dev/null) || _asl_saved=
            if [ "${_asl_saved%% *}" != "$$" ]; then
                rm -f "$SUPLOCK/pid" 2>/dev/null
                rmdir "$SUPLOCK" 2>/dev/null
                log "回收残留 supervisor 锁后归属校验失败，拒绝启动"
                return 1
            fi
            return 0
        fi
        log "检测到 supervisor 锁占用（PID $_asl_pid），拒绝重复启动"
        return 1
    fi

    # 锁目录刚创建但 PID 还未写入时不抢占；超过 30 秒才回收明显残留。
    _asl_mtime=$(stat -c %Y "$SUPLOCK" 2>/dev/null)
    _asl_now=$(date +%s 2>/dev/null)
    case "$_asl_mtime:$_asl_now" in *[!0-9:]*|:*) _asl_mtime=0 ;; esac
    if [ "$_asl_mtime" -gt 0 ] && [ $((_asl_now - _asl_mtime)) -gt 30 ] 2>/dev/null; then
        rm -f "$SUPLOCK/pid" 2>/dev/null
        rmdir "$SUPLOCK" 2>/dev/null
    fi
    log "supervisor 锁状态不明确，拒绝本次启动"
    return 1
}

release_supervisor_lock() {
    _rsl_line=$(read_node "$SUPLOCK/pid" 2>/dev/null) || _rsl_line=
    if [ "${_rsl_line%% *}" = "$$" ]; then
        rm -f "$SUPLOCK/pid" 2>/dev/null
        rmdir "$SUPLOCK" 2>/dev/null
    fi
}

trash_path() {
    [ -e "$1" ] || return 0
    mkdir -p "$TRASH" 2>/dev/null
    _tp_dst="$TRASH/$(basename "$1").$(date +%s)"
    mv "$1" "$_tp_dst" 2>/dev/null && log "已移动到临时目录: $_tp_dst"
}

set_stopped() { printf '%s\n' "$1" > "$STOPF" 2>/dev/null; }
is_stopped()  { [ "$(read_node "$STOPF" 2>/dev/null)" = "1" ]; }

stop_daemon() {
    set_stopped 1
    _sd_sp_line=$(read_node "$SUPIDF" 2>/dev/null) || _sd_sp_line=
    _sd_dp_line=$(read_node "$PIDF" 2>/dev/null) || _sd_dp_line=
    _sd_sp=${_sd_sp_line%% *}
    _sd_sp_start=${_sd_sp_line#* }
    [ "$_sd_sp_start" = "$_sd_sp_line" ] && _sd_sp_start=
    _sd_dp=${_sd_dp_line%% *}
    _sd_dp_start=${_sd_dp_line#* }
    [ "$_sd_dp_start" = "$_sd_dp_line" ] && _sd_dp_start=
    pid_is_ours "$_sd_sp" supervisor "$_sd_sp_start" && kill "$_sd_sp" 2>/dev/null
    pid_is_ours "$_sd_dp" daemon "$_sd_dp_start" && kill "$_sd_dp" 2>/dev/null
    _sd_wait=0
    while [ "$_sd_wait" -lt 25 ]; do
        _sd_alive=0
        pid_is_ours "$_sd_sp" supervisor "$_sd_sp_start" && _sd_alive=1
        pid_is_ours "$_sd_dp" daemon "$_sd_dp_start" && _sd_alive=1
        [ "$_sd_alive" = 0 ] && break
        sleep 0.2
        _sd_wait=$((_sd_wait + 1))
    done
    pid_is_ours "$_sd_sp" supervisor "$_sd_sp_start" && kill -9 "$_sd_sp" 2>/dev/null
    pid_is_ours "$_sd_dp" daemon "$_sd_dp_start" && kill -9 "$_sd_dp" 2>/dev/null
    rm -f "$PIDF" "$SUPIDF" 2>/dev/null
    log "守护进程停止流程完成（等待 $((_sd_wait / 5))s）"
}

# ---------- 屏幕状态（零 dumpsys 快路径） ----------
# 返回 1 亮屏 / 0 熄屏 / 空字符串未知（未知由调用方限频复核）。
screen_state() {
    _ss_b=$(read_node "$BL" 2>/dev/null) || _ss_b=
    case "$_ss_b" in
        ''|*[!0-9]*) ;;
        *) [ "$_ss_b" -gt 0 ] 2>/dev/null && { printf '1\n'; return 0; } ;;
    esac
    for _ss_d in "$SYS"/class/drm/card0-DSI-*/dpms; do
        [ -r "$_ss_d" ] || continue
        case "$(read_node "$_ss_d" 2>/dev/null)" in
            On|on|ON) printf '1\n'; return 0 ;;
            Off|off|OFF) printf '0\n'; return 0 ;;
        esac
    done
    printf '\n'
}

# 仅在快路径无法判定时调用，且调用方必须限频（PowerManager 是重量级 binder）。
screen_state_power() {
    _spw=$(dumpsys power 2>/dev/null)
    case "$_spw" in
        *mWakefulness=Awake*|*"Display Power: state=ON"*|*mInteractive=true*|*mScreenOn=true*) printf '1\n' ;;
        *mWakefulness=Asleep*|*mWakefulness=Dozing*|*mInteractive=false*|*mScreenOn=false*) printf '0\n' ;;
        *) printf '\n' ;;
    esac
}

# ---------- 游戏识别 ----------
STATEF=$DATADIR/state
FORCEF=$DATADIR/game.force
game_forced() { [ "$(read_node "$FORCEF" 2>/dev/null)" = "1" ]; }
set_game_force() { printf '%s\n' "$1" > "$FORCEF" 2>/dev/null; }

match_game_package() {
    case "$1" in *.*) ;; *) return 1 ;; esac
    for _mg_pat in $GAME_PATTERNS; do
        case "$1" in $_mg_pat) printf '%s\n' "$1"; return 0 ;; esac
    done
    return 1
}

# 连续漏检策略：已有游戏态时容忍一次 cgroup 短暂漏报，第二次要求兜底核验。
game_miss_policy() { # state consecutive_misses
    [ "$1" = game ] && [ "$2" -lt 2 ] 2>/dev/null && { printf 'hold\n'; return 0; }
    printf 'verify\n'
}

# 快路径：top-app cgroup 的进程 cmdline 直接给出前台包名。
# 纯 procfs 读取，实测约 1–2 ms，不触发 system_server binder dump。
front_cgroup_file() {
    for _fg_f in "$CG/top-app/cgroup.procs" "$CG/foreground/cgroup.procs" "$SYS/fs/cgroup/top-app/cgroup.procs"; do
        [ -r "$_fg_f" ] && { printf '%s\n' "$_fg_f"; return 0; }
    done
    return 1
}

detect_game_cgroup() {
    _dgc_file=$(front_cgroup_file) || return 1
    _dgc_seen=
    while IFS= read -r _dgc_pid; do
        case "$_dgc_pid" in ''|*[!0-9]*) continue ;; esac
        _dgc_cmd=
        { IFS= read -r _dgc_cmd < "$PROC/$_dgc_pid/cmdline"; } 2>/dev/null
        [ -n "$_dgc_cmd" ] || continue
        case "$_dgc_cmd" in
            */*) _dgc_cmd=${_dgc_cmd##*/} ;;
        esac
        case "$_dgc_cmd" in *' '*) _dgc_cmd=${_dgc_cmd%% *} ;; esac
        case "$_dgc_seen" in
            *" $_dgc_cmd "*) continue ;;
        esac
        _dgc_seen="$_dgc_seen $_dgc_cmd "
        _dgc_hit=$(match_game_package "$_dgc_cmd") || continue
        printf '%s\n' "$_dgc_hit"
        return 0
    done < "$_dgc_file"
    return 1
}

# 兜底路径：cgroup 不可用或需要低频复核时才走 dumpsys（约 15 ms / 次）。
detect_game_dumpsys() {
    _dgd_activity=$(dumpsys activity activities 2>/dev/null)
    _dgd_pkgs=$(printf '%s\n' "$_dgd_activity" | awk '
        /topResumedActivity|mResumedActivity|ResumedActivity/ {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^u[0-9]+$/ && i < NF) {
                    v=$(i+1); sub(/\/.*/, "", v); sub(/[},;].*$/, "", v)
                    if (v ~ /^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+$/) print v
                }
                if ($i ~ /^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\//) {
                    v=$i; sub(/\/.*/, "", v); print v
                }
            }
        }')
    for _dgd_c in $_dgd_pkgs; do
        _dgd_hit=$(match_game_package "$_dgd_c") && { printf '%s\n' "$_dgd_hit"; return 0; }
    done

    _dgd_window=$(dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' | head -n 2)
    _dgd_pkgs=$(printf '%s\n' "$_dgd_window" | awk '
        {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^u[0-9]+$/ && i < NF) {
                    v=$(i+1); sub(/\/.*/, "", v); sub(/[},;].*$/, "", v)
                    if (v ~ /^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+$/) print v
                }
                if ($i ~ /^[A-Za-z0-9_]+([.][A-Za-z0-9_]+)+\//) {
                    v=$i; sub(/\/.*/, "", v); print v
                }
            }
        }')
    for _dgd_c in $_dgd_pkgs; do
        _dgd_hit=$(match_game_package "$_dgd_c") && { printf '%s\n' "$_dgd_hit"; return 0; }
    done
    return 1
}

# 默认入口：有 cgroup 就用快路径，否则退回 dumpsys。
detect_game_pkg() {
    if front_cgroup_file >/dev/null 2>&1; then
        detect_game_cgroup
    else
        detect_game_dumpsys
    fi
}

# ---------- 模式与状态 ----------
PROFILEF=$DATADIR/profile.mode
get_profile() {
    _gp=$(read_node "$PROFILEF" 2>/dev/null) || _gp=
    case "$_gp" in auto|daily|eco) printf '%s\n' "$_gp" ;; *) printf 'auto\n' ;; esac
}

set_profile() {
    case "$1" in
        auto|daily|eco)
            _spf_tmp="$PROFILEF.tmp.$$"
            printf '%s\n' "$1" > "$_spf_tmp" 2>/dev/null || { rm -f "$_spf_tmp" 2>/dev/null; return 1; }
            mv -f "$_spf_tmp" "$PROFILEF" 2>/dev/null || { rm -f "$_spf_tmp" 2>/dev/null; return 1; }
            log "profile mode=$1"
            ;;
        *) return 1 ;;
    esac
}

write_state() {
    _ws_tmp="$STATEF.tmp.$$"
    {
        printf 'mode=%s\n' "$1"
        printf 'pkg=%s\n' "$2"
        printf 'ts=%s\n' "$(date +%s)"
    } > "$_ws_tmp" 2>/dev/null || { rm -f "$_ws_tmp" 2>/dev/null; return 1; }
    mv -f "$_ws_tmp" "$STATEF" 2>/dev/null || { rm -f "$_ws_tmp" 2>/dev/null; return 1; }
    [ "$(state_get mode 2>/dev/null)" = "$1" ] && [ "$(state_get pkg 2>/dev/null)" = "$2" ]
}

state_get() {
    [ -f "$STATEF" ] || return 1
    while IFS= read -r _sg_line; do
        case "$_sg_line" in
            "$1="*) printf '%s\n' "${_sg_line#*=}"; return 0 ;;
        esac
    done < "$STATEF"
    return 1
}

gpu_busy_value() {
    _gb=$(read_node "$GPU/gpu_busy_percentage" 2>/dev/null) || return 1
    _gb=${_gb%\%}
    _gb=$(trim_ws "$_gb")
    case "$_gb" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_gb" -le 100 ] 2>/dev/null || return 1
    printf '%s\n' "$_gb"
}

# ---------- 机型保护 ----------
# 目标设备必须匹配 SoC / GPU / 产品标识，且实际只暴露两组可区分的 CPU policy。
GETPROP=${SF_GETPROP:-getprop}
device_identity_ok() {
    _dk_soc="$($GETPROP ro.soc.model 2>/dev/null) $($GETPROP ro.vendor.soc.model 2>/dev/null)"
    _dk_gpu=$(read_node "$GPU/gpu_model" 2>/dev/null) || _dk_gpu=
    _dk_id="$($GETPROP ro.product.device 2>/dev/null) $($GETPROP ro.product.vendor.device 2>/dev/null) $($GETPROP ro.build.product 2>/dev/null) $($GETPROP ro.product.model 2>/dev/null)"
    case "$_dk_soc" in *SM8850*) ;; *) return 1 ;; esac
    case "$_dk_gpu" in *Adreno*840*|*adreno*840*) ;; *) return 1 ;; esac
    case "$_dk_id" in *OPD2513*|*"OnePlus Pad 3 Pro"*) return 0 ;; esac
    return 1
}

# Profile 写入前的统一硬件门禁。service.sh 的开机检测不是唯一防线：
# daemon 会在启动后独立运行，因此每次档位应用都必须重新确认目标设备和节点。
device_ok() {
    refresh_cpu_policies
    device_identity_ok || return 1
    [ "$CPU_TOPOLOGY_OK" = 1 ] || return 1
    [ "$WALT_OK" = 1 ] || return 1
    for _dk_f in "$CPU0/scaling_min_freq" "$CPU0/scaling_max_freq" \
                "$CPU6/scaling_min_freq" "$CPU6/scaling_max_freq"; do
        [ -r "$_dk_f" ] && [ -w "$_dk_f" ] || return 1
    done
    return 0
}
