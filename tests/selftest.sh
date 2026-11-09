#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.4 隔离自测
# 在临时目录里构造假的 sysfs / procfs / cgroup，验证：
#   拓扑识别、日常/游戏/省电档写入、恢复语义、拓扑失效 fail-closed、
#   配置白名单解析、cgroup 游戏识别、屏幕状态快路径。
# 不读写真实 /sys、不触碰正在运行的守护进程。

HERE=$(cd "${0%/*}" && pwd)
CORE=$HERE/../bin/core.sh
T=${TMPDIR:-/tmp}/sf-selftest.$$
FAIL=0
PASS=0
rm -rf "$T"
mkdir -p "$T"
trap 'rm -rf "$T"' EXIT

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

expect() { # file expected label
    _ex_got=
    [ -r "$1" ] && IFS= read -r _ex_got < "$1"
    if [ "$_ex_got" = "$2" ]; then
        ok "$3"
    else
        bad "$3 (期望 [$2] 实际 [$_ex_got])"
    fi
}

SYS=$T/sys
PROC=$T/proc
CG=$T/dev/cpuctl
DATA=$T/data
TRASH=$T/trash
export SF_SYS=$SYS SF_PROC=$PROC SF_CG=$CG SF_DATADIR=$DATA SF_TRASH=$TRASH
mkdir -p "$SYS" "$PROC" "$CG" "$DATA"
# 模拟目标设备属性，使真实设备门禁也纳入隔离测试。
cat > "$T/getprop" <<'GETPROP'
#!/bin/sh
case "$1" in
  ro.soc.model|ro.vendor.soc.model) IFS= read -r v < "$SF_DATADIR/mock_soc"; echo "$v" ;;
  ro.product.device|ro.product.vendor.device|ro.build.product) IFS= read -r v < "$SF_DATADIR/mock_device"; echo "$v" ;;
  ro.product.model) echo "OnePlus Pad 3 Pro" ;;
  *) echo "" ;;
esac
GETPROP
chmod 755 "$T/getprop"
printf 'SM8850P\n' > "$DATA/mock_soc"
printf 'OPD2513\n' > "$DATA/mock_device"
export SF_GETPROP="$T/getprop"


# ---- 假节点 ----
for c in 0 1 2 3 4 5 6 7; do mkdir -p "$SYS/devices/system/cpu/cpu$c"; done
for c in 0 1 2 3 4 5; do printf '762\n' > "$SYS/devices/system/cpu/cpu$c/cpu_capacity"; done
for c in 6 7; do printf '1024\n' > "$SYS/devices/system/cpu/cpu$c/cpu_capacity"; done

mk_policy() { # dir members freqs hs load rtg min max
    mkdir -p "$1/walt"
    printf '%s\n' "$2" > "$1/related_cpus"
    printf '%s\n' "$3" > "$1/scaling_available_frequencies"
    printf 'walt\n' > "$1/scaling_governor"
    printf '%s\n' "$4" > "$1/walt/hispeed_freq"
    printf '%s\n' "$5" > "$1/walt/hispeed_load"
    printf '%s\n' "$6" > "$1/walt/rtg_boost_freq"
    printf '20000\n' > "$1/walt/down_rate_limit_us"
    printf '0\n' > "$1/walt/up_rate_limit_us"
    printf '%s\n' "$7" > "$1/scaling_min_freq"
    printf '%s\n' "$8" > "$1/scaling_max_freq"
}

P0=$SYS/devices/system/cpu/cpufreq/policy0
P6=$SYS/devices/system/cpu/cpufreq/policy6
mkdir -p "$SYS/devices/system/cpu/cpufreq"
export P0_PATH=$SYS/devices/system/cpu/cpufreq/policy0
mk_policy "$P0" "0 1 2 3 4 5" "384000 787200 1209600 1497600 1804800 1996800 2112000 2496000 2899200 3033600" 1286400 90 787200 787200 2899200
mk_policy "$P6" "6 7" "768000 883200 1497600 1747200 1804800 1996800 2496000 3360000 4396800 4512000" 2438400 88 1497600 883200 4512000

mkdir -p "$SYS/class/backlight/panel0-backlight"
printf '100\n' > "$SYS/class/backlight/panel0-backlight/brightness"
mkdir -p "$SYS/class/drm/card0-DSI-1"
printf 'On\n' > "$SYS/class/drm/card0-DSI-1/dpms"
mkdir -p "$SYS/class/kgsl/kgsl-3d0"
printf 'Adreno840v254\n' > "$SYS/class/kgsl/kgsl-3d0/gpu_model"
printf '0 %%\n' > "$SYS/class/kgsl/kgsl-3d0/gpu_busy_percentage"
printf '1000000000\n' > "$SYS/class/kgsl/kgsl-3d0/gpuclk"
printf '1115\n' > "$SYS/class/kgsl/kgsl-3d0/max_clock_mhz"

mkdir -p "$CG/display" "$CG/top-app"
printf '10.00\n' > "$CG/display/cpu.uclamp.min"
printf '0.00\n' > "$CG/top-app/cpu.uclamp.min"

printf 'MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\n' > "$PROC/meminfo"
printf 'Filename Type Size Used Priority\n/dev/block/zram0 partition 4000000 1000000 -2\n' > "$PROC/swaps"
printf '12345.67 999.99\n' > "$PROC/uptime"

# 假前台进程：top-app 里有游戏
mkdir -p "$PROC/100" "$PROC/101" "$PROC"
printf "com.miHoYo.Genshin\n" > "$PROC/100/cmdline"
printf 'com.android.launcher3\n' > "$PROC/101/cmdline"
printf '100\n101\n' > "$CG/top-app/cgroup.procs"

run() { sh -c ". '$CORE'; $1"; }

# ---- 1. 拓扑识别 ----
OUT=$(run 'printf "%s|%s|%s|%s\n" "$CPU_TOPOLOGY_OK" "${CPU0##*/}" "${CPU6##*/}" "$WALT_OK"')
[ "$OUT" = "1|policy0|policy6|1" ] && ok "拓扑识别：两组策略、WALT 可用" || bad "拓扑识别：$OUT"

# ---- 2. 基线快照 + 日常档 ----
run 'capture_all; apply_on; printf "%s\n" $?' > "$T/rc"
expect "$T/rc" "0" "apply_on 返回成功"
expect "$P0/walt/hispeed_freq" 1497600 "日常档 hispeed_freq(低簇)"
expect "$P0/walt/hispeed_load" 88 "日常档 hispeed_load(低簇)"
expect "$P0/walt/rtg_boost_freq" 1209600 "日常档 rtg_boost_freq(低簇)"
expect "$P6/walt/hispeed_freq" 2438400 "日常档不把厂商更高的 hispeed 降下来（只升不降）"
expect "$P0/scaling_min_freq" 787200 "日常档不抬高最低频率"
expect "$CG/display/cpu.uclamp.min" "10.00" "日常档 display uclamp"
expect "$P6/walt/up_rate_limit_us" "0" "未配置时不改 up_rate_limit"

# ---- 3. 游戏档 ----
run 'apply_game' && ok "apply_game 返回成功" || bad "apply_game 返回非 0"
expect "$P0/walt/hispeed_freq" 1804800 "游戏档 hispeed_freq(低簇)"
expect "$P0/walt/hispeed_load" 80 "游戏档 hispeed_load(低簇)"
expect "$P6/walt/rtg_boost_freq" 1996800 "游戏档 rtg_boost(高簇)"
expect "$P0/walt/down_rate_limit_us" 8000 "游戏档 down_rate_limit"
expect "$CG/top-app/cpu.uclamp.min" "20.00" "游戏档 top-app uclamp"

# ---- 3.1 游戏档回到日常档：撤销自己抬高的参数，同时保留厂商原本更高值 ----
run 'apply_on' >/dev/null
expect "$P0/walt/hispeed_freq" 1497600 "游戏退出后低簇回到日常目标"
expect "$P6/walt/hispeed_freq" 2438400 "游戏退出后高簇恢复厂商高于日常目标的原值"
expect "$P0/walt/rtg_boost_freq" 1209600 "游戏退出后低簇 RTG 回到日常目标"
expect "$P6/walt/rtg_boost_freq" 1497600 "游戏退出后高簇 RTG 回到日常目标"

# ---- 4. 省电档 ----
run 'apply_eco' && ok "apply_eco 返回成功" || bad "apply_eco 返回非 0"
expect "$P0/scaling_max_freq" 2496000 "省电档上限(低簇)"
expect "$P6/scaling_max_freq" 1996800 "省电档上限(高簇)"
expect "$CG/display/cpu.uclamp.min" "0.00" "省电档 display uclamp=0"

# ---- 5. 完全恢复 ----
run 'apply_off' && ok "apply_off 返回成功" || bad "apply_off 返回非 0"
expect "$P0/walt/hispeed_freq" 1286400 "恢复 hispeed_freq(低簇)"
expect "$P0/walt/hispeed_load" 90 "恢复 hispeed_load"
expect "$P6/walt/down_rate_limit_us" 20000 "恢复 down_rate_limit"
expect "$P0/scaling_max_freq" 2899200 "恢复 max_freq(低簇)"
expect "$P6/scaling_max_freq" 4512000 "恢复 max_freq(高簇)"
expect "$CG/top-app/cpu.uclamp.min" "0.00" "恢复 top-app uclamp"
[ -s "$DATA/applied.txt" ] && bad "恢复后 applied.txt 应为空" || ok "恢复后 applied.txt 已清空"

# ---- 6. 拓扑失效 fail-closed ----
mv "$P6" "$T/policy6.off"
printf '111\n' > "$P0/walt/hispeed_freq"
run 'apply_on; printf "%s\n" $?' > "$T/rc2"
expect "$T/rc2" "2" "拓扑无效时 apply_on 返回 2"
expect "$P0/walt/hispeed_freq" 111 "拓扑无效时不写入任何参数"
mv "$T/policy6.off" "$P6"

# ---- 6.1 设备身份门禁：不匹配时任何档位都不得写入 ----
printf 'OTHER_SOC\n' > "$DATA/mock_soc"
OUT=$(run 'apply_game; printf "%s\n" $?')
[ "$OUT" = "2" ] && ok "非目标 SoC 被安全门禁拒绝" || bad "非目标 SoC 门禁返回：[$OUT]"
expect "$P0/walt/hispeed_freq" 111 "设备不匹配时不写入 WALT 节点"
printf 'SM8850P\n' > "$DATA/mock_soc"

# ---- 6.2 必需 WALT 节点缺失时 fail-closed ----
mv "$P0/walt/rtg_boost_freq" "$T/rtg.off"
OUT=$(run 'apply_on; printf "%s\n" $?')
[ "$OUT" = "2" ] && ok "必需 WALT 节点缺失时拒绝应用" || bad "WALT 缺失门禁返回：[$OUT]"
expect "$P0/walt/hispeed_freq" 111 "WALT 节点不完整时不发生部分写入"
mv "$T/rtg.off" "$P0/walt/rtg_boost_freq"

# ---- 7. 配置白名单解析（注入无效，合法键生效）----
mkdir -p "$DATA"
{
    printf 'ON_HS0=2112000\n'
    printf 'GAME_PATTERNS="com.test.* com.foo.bar"\n'
    printf 'ON_LOAD0=$(reboot)\n'
    printf 'ON_MIN0=1228800; rm -rf /data\n'
    printf 'GARBAGE=1\n'
} > "$DATA/config.sh"
OUT=$(run 'printf "%s|%s|%s\n" "$ON_HS0" "$ON_LOAD0" "$GAME_PATTERNS"')
[ "$OUT" = "2112000|88|com.test.* com.foo.bar" ] && ok "配置白名单：非法值被忽略，合法值生效" || bad "配置解析：$OUT"
rm -f "$DATA/config.sh"

# ---- 8. 游戏识别（cgroup 快路径，不调用 dumpsys）----
OUT=$(run 'detect_game_cgroup')
[ "$OUT" = "com.miHoYo.Genshin" ] && ok "cgroup 快路径识别前台游戏" || bad "cgroup 识别：[$OUT]"
OUT=$(run 'detect_game_pkg')
[ "$OUT" = "com.miHoYo.Genshin" ] && ok "detect_game_pkg 默认走快路径" || bad "detect_game_pkg：[$OUT]"
OUT=$(run 'game_miss_policy game 1')
[ "$OUT" = "hold" ] && ok "游戏识别单次漏检保留当前档位" || bad "游戏漏检策略：[$OUT]"
OUT=$(run 'game_miss_policy game 2')
[ "$OUT" = "verify" ] && ok "连续漏检触发兜底验证" || bad "游戏漏检策略：[$OUT]"
OUT=$(run 'game_miss_policy on 1')
[ "$OUT" = "verify" ] && ok "非游戏态不错误保留游戏档" || bad "非游戏漏检策略：[$OUT]"
printf 'com.android.launcher3\n' > "$CG/top-app/cgroup.procs"
OUT=$(run 'detect_game_cgroup; printf "%s\n" $?')
[ "$OUT" = "1" ] && ok "非游戏前台不误判" || bad "误判：[$OUT]"

# ---- 9. 屏幕状态快路径 ----
OUT=$(run 'screen_state')
[ "$OUT" = "1" ] && ok "背光>0 判定亮屏" || bad "screen_state：[$OUT]"
printf '0\n' > "$SYS/class/backlight/panel0-backlight/brightness"
printf 'Off\n' > "$SYS/class/drm/card0-DSI-1/dpms"
OUT=$(run 'screen_state')
[ "$OUT" = "0" ] && ok "背光 0 + dpms Off 判定熄屏" || bad "screen_state(off)：[$OUT]"
rm -f "$SYS/class/drm/card0-DSI-1/dpms"
OUT=$(run 'screen_state')
[ -z "$OUT" ] && ok "无法判定时返回空（交给限频复核）" || bad "screen_state(unknown)=[$OUT]"

# ---- 10. 写入记录与回滚归属 ----
OUT=$(run 'record_applied /tmp/x 5; applied_of /tmp/x; forget_applied /tmp/x; applied_of /tmp/x; printf "END"')
[ "$OUT" = "5
END" ] && ok "applied 记录写入/读取/删除" || bad "applied 记录：[$OUT]"

# ---- 11. 频率对齐（内核频率表变化时取最接近的可用值）----
# 上一项故意把节点改为 111 验证 fail-closed；这里先恢复到测试基线。
printf '1286400\n' > "$P0/walt/hispeed_freq"
OUT=$(run 'snap_freq "$CPU0" 1500000 up; snap_freq "$CPU0" 1500000 down')
[ "$OUT" = "1804800
1497600" ] && ok "snap_freq up/down 取最接近可用频率" || bad "snap_freq：[$OUT]"
OUT=$(run 'set_freq "$P0_PATH/walt/hispeed_freq" 1500000 "$CPU0" up; read_node "$P0_PATH/walt/hispeed_freq"')
[ "$OUT" = "1804800" ] && ok "set_freq 写入对齐后的频率" || bad "set_freq 对齐：[$OUT]"

# ---- 12. 省电上限在“频率对齐”后仍能恢复（回归）----
cp "$P6/scaling_available_frequencies" "$T/freq.bak"
printf '768000 883200 1497600 1747200 1804800 1977600 2496000 4512000\n' > "$P6/scaling_available_frequencies"
printf '4512000\n' > "$P6/scaling_max_freq"
run 'apply_eco' >/dev/null
expect "$P6/scaling_max_freq" 1977600 "省电上限对齐到内核支持的 1977600"
run 'apply_on' >/dev/null
expect "$P6/scaling_max_freq" 4512000 "切回日常档恢复省电上限"
cp "$T/freq.bak" "$P6/scaling_available_frequencies"
run 'apply_off' >/dev/null

# ---- 13. 游戏档最低频率经对齐后仍能回落（回归）----
printf 'GAME_MIN0=1800000\n' > "$DATA/config.sh"
run 'apply_game' >/dev/null
expect "$P0/scaling_min_freq" 1804800 "游戏档最低频率对齐到 1804800"
run 'apply_on' >/dev/null
expect "$P0/scaling_min_freq" 787200 "退出游戏后最低频率回落原厂值"
rm -f "$DATA/config.sh"
run 'apply_off' >/dev/null

# ---- 14. ON_HS_POLICY=set 仍可强制写入绝对值 ----
printf 'ON_HS_POLICY=set\n' > "$DATA/config.sh"
run 'apply_on' >/dev/null
expect "$P6/walt/hispeed_freq" 1804800 "ON_HS_POLICY=set 时写入目标值"
rm -f "$DATA/config.sh"
run 'apply_off' >/dev/null

# ---- 15. 漂移检测与自愈 ----
run 'apply_game' >/dev/null
printf '1000000\n' > "$P0/walt/hispeed_freq"
OUT=$(run 'drift_detect game')
[ "$OUT" -ge 1 ] 2>/dev/null && ok "检测到 WALT 参数漂移（$OUT 项）" || bad "drift_detect=$OUT"
OUT=$(run 'apply_game; drift_detect game')
[ "$OUT" -ge 1 ] 2>/dev/null && ok "外部改写后保持漂移告警，不争抢节点" || bad "外部改写漂移状态：$OUT"
expect "$P0/walt/hispeed_freq" 1000000 "自愈流程不覆盖外部模块修改的值"
run 'apply_off' >/dev/null

# ---- 16. 游戏专属 up_rate_limit 在退出游戏时恢复 ----
printf 'GAME_UP_RATE=12000\n' > "$DATA/config.sh"
run 'apply_game' >/dev/null
expect "$P0/walt/up_rate_limit_us" 12000 "游戏档按配置写入低簇 up_rate_limit"
expect "$P6/walt/up_rate_limit_us" 12000 "游戏档按配置写入高簇 up_rate_limit"
rm -f "$DATA/config.sh"
run 'apply_on' >/dev/null
expect "$P0/walt/up_rate_limit_us" 0 "退出游戏后低簇 up_rate_limit 恢复原值"
expect "$P6/walt/up_rate_limit_us" 0 "退出游戏后高簇 up_rate_limit 恢复原值"
run 'apply_off' >/dev/null

# ---- 16.1 可选 up_rate_limit 节点不存在时跳过，不阻断主调度 ----
P0_UP_BAK=$T/up0.bak
P6_UP_BAK=$T/up6.bak
mv "$P0/walt/up_rate_limit_us" "$P0_UP_BAK"
mv "$P6/walt/up_rate_limit_us" "$P6_UP_BAK"
printf 'GAME_UP_RATE=12000\n' > "$DATA/config.sh"
OUT=$(run 'apply_game; printf "%s" "$?"')
[ "$OUT" = "0" ] && ok "缺少可选 up_rate_limit 时游戏档仍可安全运行" || bad "可选节点缺失处理：[$OUT]"
rm -f "$DATA/config.sh"
run 'apply_off' >/dev/null
mv "$P0_UP_BAK" "$P0/walt/up_rate_limit_us"
mv "$P6_UP_BAK" "$P6/walt/up_rate_limit_us"

# ---- 17. 单节点延迟采集：未做全量快照时，写入前必须先保存原始值 ----
printf '1286400\n' > "$P0/walt/hispeed_freq"
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
OUT=$(run 'SF_WRITE_FAILED=0; set_val "$W0/hispeed_freq" 1497600; printf "%s|%s|%s" "$(def_of "$W0/hispeed_freq")" "$(applied_of "$W0/hispeed_freq")" "$(read_node "$W0/hispeed_freq")"')
[ "$OUT" = "1286400|1497600|1497600" ] && ok "写入前按节点保存原始值并登记归属" || bad "单节点快照/归属：[$OUT]"
run 'restore_one_if_owned "$W0/hispeed_freq"' >/dev/null
expect "$P0/walt/hispeed_freq" 1286400 "单节点快照可用于安全恢复"

# ---- 18. 恢复记录落盘失败：必须尝试回滚未登记写入 ----
printf '1286400\n' > "$P0/walt/hispeed_freq"
: > "$DATA/defaults.txt"
OUT=$(run 'record_applied() { return 1; }; SF_WRITE_FAILED=0; set_val "$W0/hispeed_freq" 1497600; printf "%s|%s" "$(read_node "$W0/hispeed_freq")" "$SF_WRITE_FAILED"')
[ "$OUT" = "1286400|1" ] && ok "applied 记录失败时安全回滚未登记写入" || bad "记录失败回滚：[$OUT]"

# ---- 19. 外部模块改写后不得覆盖其新值 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
run 'set_val "$W0/hispeed_freq" 1497600' >/dev/null
printf '1555200\n' > "$P0/walt/hispeed_freq"
run 'restore_one_if_owned "$W0/hispeed_freq"' >/dev/null
expect "$P0/walt/hispeed_freq" 1555200 "检测到外部改写时不覆盖外部值"


# ---- 20. 档位切换时检测到外部占用，不覆盖外部值 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '1286400\n' > "$P0/walt/hispeed_freq"
run 'capture "$W0/hispeed_freq"; set_val "$W0/hispeed_freq" 1497600' >/dev/null
printf '1555200\n' > "$P0/walt/hispeed_freq"
OUT=$(run 'SF_WRITE_CONFLICT=0; set_val "$W0/hispeed_freq" 1804800; printf "%s|%s|%s" "$(read_node "$W0/hispeed_freq")" "$SF_WRITE_CONFLICT" "$(ownership_conflict_count)"')
[ "$OUT" = "1555200|1|1" ] && ok "档位切换发现外部占用后跳过写入" || bad "外部占用保护：[$OUT]"

# ---- 21. 恢复记录中的路径必须属于模块白名单 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '999\n' > "$PROC/sys_kernel_test"
printf '%s 1\n' "$PROC/sys_kernel_test" > "$DATA/applied.txt"
printf '%s 0\n' "$PROC/sys_kernel_test" > "$DATA/defaults.txt"
OUT=$(run 'restore_one_if_owned "$SF_PROC/sys_kernel_test" >/dev/null 2>&1; printf "%s" "$?"')
[ "$OUT" != "0" ] && ok "恢复流程拒绝白名单外路径" || bad "白名单外恢复路径被接受"

# ---- 22. 已有本模块写入值时，恢复记录失败应回到写入前的档位值 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '1286400\n' > "$P0/walt/hispeed_freq"
run 'capture "$W0/hispeed_freq"; set_val "$W0/hispeed_freq" 1497600' >/dev/null
OUT=$(run 'record_applied() { return 1; }; SF_WRITE_FAILED=0; set_val "$W0/hispeed_freq" 1804800; printf "%s|%s|%s" "$(read_node "$W0/hispeed_freq")" "$(applied_of "$W0/hispeed_freq")" "$SF_WRITE_FAILED"')
[ "$OUT" = "1497600|1497600|1" ] && ok "记录失败回滚到切换前值，保留旧归属记录" || bad "档位切换回滚：[$OUT]"


# ---- 23. supervisor 单实例锁阻止并发启动 ----
OUT=$(run '
    _test_pid=$$
    mkdir -p "$PROC/$_test_pid"
    printf "/system/bin/sh /data/adb/modules/smoothflow/bin/supervisor.sh\0" > "$PROC/$_test_pid/cmdline"
    acquire_supervisor_lock; _first=$?
    acquire_supervisor_lock; _second=$?
    release_supervisor_lock
    printf "%s|%s" "$_first" "$_second"
')
[ "$OUT" = "0|1" ] && ok "supervisor 锁允许首实例并拒绝重复实例" || bad "supervisor 单实例锁：[$OUT]"

# ---- 24. set_val 拒绝非法目标值，不触碰节点 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '1286400\n' > "$P0/walt/hispeed_freq"
OUT=$(run 'SF_WRITE_FAILED=0; set_val "$W0/hispeed_freq" "1497600;reboot" >/dev/null 2>&1; printf "%s|%s|%s" "$(read_node "$W0/hispeed_freq")" "$SF_WRITE_FAILED" "$(applied_of "$W0/hispeed_freq")"')
[ "$OUT" = "1286400|1|" ] && ok "set_val 拒绝非法目标值且不写入节点" || bad "非法目标值校验：[$OUT]"

# ---- 25. uclamp 小数精度：完整比较、归属记录与漂移检测 ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '10.50\n' > "$CG/display/cpu.uclamp.min"
OUT=$(run 'SF_WRITE_FAILED=0; set_pct "$DISPLAY_UCLAMP_PATH" 10; printf "%s|%s|%s|%s" "$(read_node "$DISPLAY_UCLAMP_PATH")" "$(def_of "$DISPLAY_UCLAMP_PATH")" "$(applied_of "$DISPLAY_UCLAMP_PATH")" "$SF_WRITE_FAILED"')
[ "$OUT" = "10.00|10.50|10.00|0" ] && ok "uclamp 10.50 正确收敛到 10.00 并登记原值" || bad "uclamp 小数写入：[$OUT]"
run 'restore_one_if_owned "$DISPLAY_UCLAMP_PATH"' >/dev/null
expect "$CG/display/cpu.uclamp.min" "10.50" "uclamp 小数原值可安全恢复"
run 'apply_on' >/dev/null
printf '10.50\n' > "$CG/display/cpu.uclamp.min"
OUT=$(run 'drift_detect on')
[ "$OUT" -ge 1 ] 2>/dev/null && ok "drift_detect 能识别 uclamp 小数偏差" || bad "uclamp 小数漂移检测：[$OUT]"
run 'apply_off' >/dev/null

printf '\n通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
