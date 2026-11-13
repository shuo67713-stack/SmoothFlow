#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# SmoothFlow 5.0.6-rc7 隔离自测
# 在临时目录里构造假的 sysfs / procfs / cgroup，验证：
#   拓扑识别、日常/游戏/省电档写入、恢复语义、拓扑失效 fail-closed、
#   配置白名单解析、cgroup 游戏识别、屏幕状态快路径。
# 不读写真实 /sys、不触碰正在运行的守护进程。

HERE=$(cd "${0%/*}" && pwd)
if [ -f "$HERE/core.sh" ]; then CORE=$HERE/core.sh; else CORE=$HERE/../bin/core.sh; fi
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
export SF_TEST_MODE=1 SF_SYS=$SYS SF_PROC=$PROC SF_CG=$CG SF_DATADIR=$DATA SF_TRASH=$TRASH
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

# rc6 起 lock_profile / supervisor 锁在发布属主记录前要求能读到自身
# starttime（与 daemon/session 锁既有守卫一致，读不到则拒绝发布残缺记录）。
# run 子进程是真实进程，但夹具的假 /proc 里没有它的 stat 条目，故在每个
# run 块执行前把子进程自身的 stat 建模进假 /proc（starttime 固定 424242，
# 仅供身份比对；需要真实身份语义的条目在块内自行改用 /proc，与既有惯例同）。
run() { sh -c ". '$CORE'; mkdir -p \"\$PROC/\$\$\" 2>/dev/null; printf '%s (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 424242\n' \"\$\$\" > \"\$PROC/\$\$/stat\" 2>/dev/null; $1"; }

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
expect "$P0/walt/hispeed_load" 78 "游戏档 hispeed_load(低簇)"
expect "$P6/walt/rtg_boost_freq" 1996800 "游戏档 rtg_boost(高簇)"
expect "$P0/walt/down_rate_limit_us" 10000 "游戏档 down_rate_limit"
expect "$P0/walt/hispeed_load" 78 "游戏档低簇 hispeed_load"
expect "$P6/walt/hispeed_load" 78 "游戏档高簇 hispeed_load"
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
expect "$P0/scaling_min_freq" 787200 "退出游戏后最低频率回落基线值"
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

# ---- 26. stop_daemon 的 PID 文件清理不得删除并发写入的新实例记录 ----
printf '111 222\n' > "$DATA/daemon.pid"
OUT=$(run 'remove_pidfile_if_unchanged "$PIDF" "111 222" 1; [ -f "$PIDF" ]; printf "%s" "$?"')
[ "$OUT" = 1 ] && ok "PID 文件内容未变化时允许清理旧记录" || bad "旧 PID 文件清理：[$OUT]"
printf '333 444\n' > "$DATA/daemon.pid"
OUT=$(run 'remove_pidfile_if_unchanged "$PIDF" "111 222" 1; read_node "$PIDF"')
[ "$OUT" = "333 444" ] && ok "PID 文件已被新实例更新时保留新记录" || bad "并发 PID 文件保护：[$OUT]"
rm -f "$DATA/daemon.pid"
: > "$DATA/daemon.pid"
OUT=$(run 'remove_pidfile_if_unchanged "$PIDF" "" 1; [ -e "$PIDF" ]; printf "%s" "$?"')
[ "$OUT" = 1 ] && ok "空 PID 文件可按捕获状态清理" || bad "空 PID 文件清理：[$OUT]"


# ---- 27. 配置热变更后按实际归属值恢复频率节点（M1） ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
rm -f "$DATA/config.sh"
printf 'ECO_MAX6=1996800\n' > "$DATA/config.sh"
OUT=$(run '
    load_config; validate_config; apply_eco >/dev/null || exit 9
    _eco_written=$(read_node "$CPU6/scaling_max_freq")
    printf "ECO_MAX6=2496000\\n" > "$DATADIR/config.sh"
    load_config; validate_config; apply_on >/dev/null || exit 8
    printf "%s|%s" "$_eco_written" "$(read_node "$CPU6/scaling_max_freq")"
')
[ "$OUT" = "1996800|4512000" ] && ok "省电档配置变更后高簇 max 按归属记录恢复基线" || bad "M1 省电 max 配置变更恢复：[$OUT]"
run 'apply_off' >/dev/null
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf 'GAME_MIN0=1800000\n' > "$DATA/config.sh"
OUT=$(run '
    load_config; validate_config; apply_game >/dev/null || exit 9
    _game_written=$(read_node "$CPU0/scaling_min_freq")
    printf "GAME_MIN0=0\\n" > "$DATADIR/config.sh"
    load_config; validate_config; apply_on >/dev/null || exit 8
    printf "%s|%s" "$_game_written" "$(read_node "$CPU0/scaling_min_freq")"
')
[ "$OUT" = "1804800|787200" ] && ok "游戏档配置变更后低簇 min 按归属记录恢复基线" || bad "M1 游戏 min 配置变更恢复：[$OUT]"
rm -f "$DATA/config.sh"
run 'apply_off' >/dev/null

# ---- 28. capture 修复同路径畸形空快照行（S9） ----
: > "$DATA/defaults.txt"
: > "$DATA/applied.txt"
printf '%s \\n%s 123\n' "$W0/hispeed_freq" "$W0/hispeed_freq" > "$DATA/defaults.txt"
printf '1286400\n' > "$P0/walt/hispeed_freq"
OUT=$(run 'capture "$W0/hispeed_freq" >/dev/null; printf "%s|%s" "$(def_of "$W0/hispeed_freq")" "$(grep -c "^$W0/hispeed_freq " "$DEF" 2>/dev/null)"')
[ "$OUT" = "1286400|1" ] && ok "capture 替换畸形空快照行且不产生重复路径" || bad "畸形快照修复：[$OUT]"


# ---- 29. stop_daemon 必须对“仍存活/身份不确定”返回失败（M3） ----
OUT=$(run '
    mkdir -p "$PROC/4242"
    printf "4242 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999\\n" > "$PROC/4242/stat"
    printf "/system/bin/sh /data/adb/modules/smoothflow/bin/daemon.sh\\n" > "$PROC/4242/cmdline"
    printf "4242 999\\n" > "$PIDF"
    kill() { return 0; }
    sleep() { :; }
    pid_is_ours() { [ -d "$PROC/$1" ] && [ "$2" = daemon ]; }
    stop_daemon >/dev/null 2>&1; _rc=$?
    printf "%s|%s" "$_rc" "$(read_node "$PIDF")"
')
case "$OUT" in 1\|4242\ 999) ok "stop_daemon 对仍存活的 daemon 返回失败并保留 PID 记录" ;; *) bad "stop_daemon 活进程失败语义：[$OUT]" ;; esac
OUT=$(run '
    rm -rf "$PROC/4242"
    kill() { return 0; }
    sleep() { :; }
    pid_is_ours() { [ -d "$PROC/$1" ] && [ "$2" = daemon ]; }
    stop_daemon >/dev/null 2>&1; _rc=$?
    printf "%s|" "$_rc"; if [ -e "$PIDF" ]; then printf present; else printf absent; fi
')
[ "$OUT" = "0|absent" ] && ok "daemon 进程消失后 stop_daemon 才报告成功并清理 PID" || bad "stop_daemon 已退出语义：[$OUT]"

OUT=$(run '
    mkdir -p "$PROC/4243"
    printf "4243 (other worker) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 999\\n" > "$PROC/4243/stat"
    printf "other_process\\n" > "$PROC/4243/cmdline"
    printf "4243 999\\n" > "$PIDF"
    kill() { printf called >> "$DATADIR/kill_called"; return 0; }
    sleep() { :; }
    pid_is_ours() { return 1; }
    stop_daemon >/dev/null 2>&1; _rc=$?
    printf "%s|" "$_rc"; if [ -e "$DATADIR/kill_called" ]; then printf killed; else printf untouched; fi
')
[ "$OUT" = "1|untouched" ] && ok "身份校验不通过时 stop_daemon 不误杀且返回失败" || bad "stop_daemon 误杀保护：[$OUT]"



# ---- 30. 锁属主 PID 复用与活进程判定（M2） ----
OUT=$(run '
    mkdir -p "$PROC/4244" "$PROC/4245" "$DATADIR/lock-reused" "$DATADIR/lock-live"
    printf "4244 (old owner) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 222\\n" > "$PROC/4244/stat"
    printf "4245 (live owner) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 333\\n" > "$PROC/4245/stat"
    printf "4244 111\\n" > "$DATADIR/lock-reused/pid"
    printf "4245 333\\n" > "$DATADIR/lock-live/pid"
    lock_owner_stale "$DATADIR/lock-reused"; _reused=$?
    lock_owner_stale "$DATADIR/lock-live"; _live=$?
    printf "%s|%s" "$_reused" "$_live"
')
[ "$OUT" = "0|1" ] && ok "锁回收识别 PID 重用，同时保护启动时间匹配的活属主" || bad "锁属主身份判定：[$OUT]"

# ---- 31. restore_all 包装函数直接覆盖 ----
OUT=$(run 'restore_all >/dev/null 2>&1; printf "%s" "$?"')
[ "$OUT" = 0 ] && ok "restore_all 包装函数可直接执行" || bad "restore_all 直接测试：[$OUT]"

# ---- 32. 真正的 pid_is_ours 身份校验（伪造 /proc） ----
OUT=$(run '
    mkdir -p "$PROC/4250" "$PROC/4251" "$PROC/4252"
    printf "4250 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 500\n" > "$PROC/4250/stat"
    printf "/system/bin/sh /data/adb/modules/smoothflow/bin/daemon.sh\n" > "$PROC/4250/cmdline"
    printf "4251 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 501\n" > "$PROC/4251/stat"
    printf "/system/bin/sh /data/adb/modules/smoothflow/bin/daemon.sh\n" > "$PROC/4251/cmdline"
    printf "4252 (sh) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 500\n" > "$PROC/4252/stat"
    printf "other_process\n" > "$PROC/4252/cmdline"
    pid_is_ours 4250 daemon 500; _good=$?
    pid_is_ours 4251 daemon 500; _reuse=$?
    pid_is_ours 4252 daemon 500; _cmd=$?
    printf "%s|%s|%s" "$_good" "$_reuse" "$_cmd"
')
[ "$OUT" = "0|1|1" ] && ok "pid_is_ours 真函数验证启动时间与 cmdline" || bad "pid_is_ours 真函数测试：[$OUT]"

# ---- 33. 活跃 reap gate 必须 fail-closed，且不能被并发等待者删除 ----
OUT=$(run '
    mkdir -p "$PROC/4260" "$DATADIR/live-gate.reap"
    printf "4260 (owner) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 660\\n" > "$PROC/4260/stat"
    printf "4260 660\\n" > "$DATADIR/live-gate.reap/pid"
    reap_gate_stale "$DATADIR/live-gate.reap"; _rc=$?
    printf "%s|%s" "$_rc" "$( [ -d "$DATADIR/live-gate.reap" ] && echo present || echo absent )"
')
[ "$OUT" = "1|present" ] && ok "活跃 reap gate 保持 fail-closed，不被回收" || bad "活跃 reap gate 保护：[$OUT]"



# ---- 34. sf_stop：停止后恢复全部受管节点并清空会话状态 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    capture_all
    _orig=$(read_node "$W0/hispeed_load")
    apply_game >/dev/null 2>&1
    _mid=$(read_node "$W0/hispeed_load")
    sf_stop >/dev/null 2>&1; _rc=$?
    _after=$(read_node "$W0/hispeed_load")
    is_stopped; _stopped=$?
    printf "%s|%s|%s|%s|%s|%s" "$_rc" "$_mid" "$([ "$_after" = "$_orig" ] && echo same || echo diff)" "$_stopped" "$([ -s "$APPLIED" ] && echo nonempty || echo empty)" "$([ -s "$DEF" ] && echo nonempty || echo empty)"
')
[ "$OUT" = "0|78|same|0|empty|empty" ] && ok "sf_stop 恢复原始参数并清空会话状态" || bad "sf_stop 生命周期：[$OUT]"

# ---- 35. 脏会话重新初始化：遗留未恢复记录先恢复，基线重读当前值 ----
OUT=$(run '
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK"
    capture_all
    _orig=$(read_node "$W0/hispeed_load")
    apply_game >/dev/null 2>&1
    reinit_session; _rc=$?
    _after=$(read_node "$W0/hispeed_load")
    capture_all
    _defv=$(def_of "$W0/hispeed_load")
    printf "%s|%s|%s" "$_rc" "$([ "$_after" = "$_orig" ] && echo same || echo diff)" "$([ "$_defv" = "$_orig" ] && echo same || echo diff)"
')
[ "$OUT" = "0|same|same" ] && ok "重新初始化先恢复遗留状态，原始参数重新读取" || bad "脏会话重新初始化：[$OUT]"

# ---- 36. 空状态下 sf_stop 与 reinit_session 幂等 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    sf_stop >/dev/null 2>&1; _rc1=$?
    reinit_session; _rc2=$?
    printf "%s|%s" "$_rc1" "$_rc2"
')
[ "$OUT" = "0|0" ] && ok "空状态停止与重新初始化幂等" || bad "幂等性：[$OUT]"

# ---- 37. 手动启停全周期：真实 supervisor/daemon 拉起、应用、停止恢复 ----
# pid_is_ours 按正式安装路径片段 smoothflow/bin/*.sh 校验进程身份，
# 因此把 bin/ 复制到名为 smoothflow 的目录作为本节的模块根。
MODROOT="$T/smoothflow"
mkdir -p "$MODROOT"
cp -r "$HERE/../bin" "$MODROOT/"
# 拉起的 supervisor/daemon 必须与自测共用测试模式 core（发布包里的
# bin/core.sh 已固化真实路径，不读 SF_* 环境）；以本套件选定的 $CORE 覆盖。
cp "$CORE" "$MODROOT/bin/core.sh"
export MODDIR="$MODROOT"
OUT=$(run '
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK"
    PROC=/proc; export SF_PROC=/proc
    capture_all
    _orig=$(read_node "$W0/hispeed_load")
    sf_start 1 >/dev/null 2>&1; _rc=$?
    _w=0; while [ "$_w" -lt 15 ]; do daemon_alive && break; sleep 0.2; _w=$((_w + 1)); done
    _sup_line=$(read_node "$SUPIDF"); _sp=${_sup_line%% *}; _sp_start=${_sup_line#* }
    _dae_line=$(read_node "$PIDF"); _dp=${_dae_line%% *}; _dp_start=${_dae_line#* }
    supervisor_alive; _sup=$?
    daemon_alive; _dae=$?
    apply_game >/dev/null 2>&1
    sf_stop >/dev/null 2>&1; _src=$?
    stop_daemon >/dev/null 2>&1
    _sp_live=0; if [ -d "/proc/$_sp" ]; then _st=$(proc_state "$_sp"); case "$_st" in Z|X) ;; *) _sp_live=1 ;; esac; fi
    _dp_live=0; if [ -d "/proc/$_dp" ]; then _st=$(proc_state "$_dp"); case "$_st" in Z|X) ;; *) _dp_live=1 ;; esac; fi
    _after=$(read_node "$W0/hispeed_load")
    printf "%s|%s|%s|%s|%s|%s|%s|%s" "$_rc" "$_sup" "$_dae" "$_src" "$([ "$_after" = "$_orig" ] && echo same || echo diff)" "$([ -f "$PIDF" ] && echo present || echo gone)" "$_sp_live" "$_dp_live"
')
[ "$OUT" = "0|0|0|0|same|gone|0|0" ] && ok "手动启动拉起守护、停止后恢复并确认进程退出" || bad "手动启停全周期：[$OUT]"

# ---- 38. Supervisor 退避状态机：指数退避、上限、稳定复位与熔断 ----
OUT=$(run '
    a=$(supervisor_backoff_update 1 0 10)
    b=$(supervisor_backoff_update 1 1 10)
    c=$(supervisor_backoff_update 1 2 20)
    d=$(supervisor_backoff_update 1 7 300)
    e=$(supervisor_backoff_update 60 7 300)
    printf "%s|%s|%s|%s|%s" "$a" "$b" "$c" "$d" "$e"
')
[ "$OUT" = "1 10 0|2 20 0|3 40 0|8 300 1|0 10 0" ] && ok "Supervisor 指数退避、300 秒上限、8 次熔断和稳定复位" || bad "Supervisor 退避状态机：[$OUT]"

# ---- 39. daemon 原子锁与 session 生命周期锁可获取并按属主释放 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    acquire_daemon_lock; _a=$?
    [ -d "$DAEMON_LOCK" ] && _ad=1 || _ad=0
    release_daemon_lock
    acquire_session_lock; _b=$?
    [ -d "$SESSION_LOCK" ] && _se=1 || _se=0
    release_session_lock
    printf "%s|%s|%s|%s|%s|%s" "$_a" "$_ad" "$([ ! -e "$DAEMON_LOCK" ] && echo gone || echo present)" "$_b" "$_se" "$([ ! -e "$SESSION_LOCK" ] && echo gone || echo present)"
')
[ "$OUT" = "0|1|gone|0|1|gone" ] && ok "daemon 与 session 锁获取、归属校验及释放" || bad "daemon/session 锁：[$OUT]"

# ---- 40. stale reap gate 启动恢复：只回收能确认 PID 已死亡的 gate ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    _gate="$DATADIR/test.reap"
    mkdir -p "$_gate"
    printf "99999999 1\n" > "$_gate/pid"
    recover_stale_reap_gate "$_gate"; _dead=$?
    [ ! -e "$_gate" ] && _gone=1 || _gone=0
    mkdir -p "$_gate"
    _self_start=$(proc_start_time $$)
    printf "%s %s\n" "$$" "$_self_start" > "$_gate/pid"
    recover_stale_reap_gate "$_gate" >/dev/null 2>&1; _live=$?
    [ -d "$_gate" ] && _kept=1 || _kept=0
    printf "%s|%s|%s|%s" "$_dead" "$_gone" "$_live" "$_kept"
    rm -rf "$_gate"
')
[ "$OUT" = "0|1|1|1" ] && ok "reap gate 恢复只清理已确认死亡属主，活跃属主保持 fail-closed" || bad "stale reap gate 恢复：[$OUT]"

# ---- 41. session .reap gate 无属主证明时 fail-closed，有死亡 PID+starttime 时可恢复 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -rf "$SESSION_LOCK" "$SESSION_LOCK.reap"
    mkdir -p "$SESSION_LOCK.reap"
    recover_stale_reap_gate "$SESSION_LOCK.reap" >/dev/null 2>&1; _missing=$?
    [ -d "$SESSION_LOCK.reap" ] && _kept=1 || _kept=0
    rm -rf "$SESSION_LOCK.reap"
    mkdir -p "$SESSION_LOCK.reap"
    printf "99999999 1\n" > "$SESSION_LOCK.reap/pid"
    acquire_session_lock >/dev/null 2>&1; _acq=$?
    [ ! -e "$SESSION_LOCK.reap" ] && _recovered=1 || _recovered=0
    release_session_lock
    printf "%s|%s|%s|%s" "$_missing" "$_kept" "$_acq" "$_recovered"
')
[ "$OUT" = "1|1|0|1" ] && ok "session reap gate 缺少属主证明时保留，确认死亡属主后才恢复" || bad "session reap gate：[$OUT]"

# ---- 42. PID 文件缺失/过期时，stop_daemon 能从 supervisor/daemon 锁记录识别实例 ----
OUT=$(run '
    rm -f "$STOPF" "$DATADIR/killed"
    printf "999989 99\n" > "$SUPIDF"
    printf "999990 100\n" > "$PIDF"
    mkdir -p "$SUPLOCK" "$DAEMON_LOCK"
    printf "999991 101\n" > "$SUPLOCK/pid"
    printf "999992 201\n" > "$DAEMON_LOCK/pid"
    _pid_calls=0
    pid_is_ours() {
        case "$1:$2" in 999991:supervisor|999992:daemon)
            _pid_calls=$((_pid_calls + 1))
            [ "$_pid_calls" -le 2 ] && return 0
            ;;
        esac
        return 1
    }
    kill() { printf "%s\n" "$*" >> "$DATADIR/killed"; return 0; }
    stop_daemon >/dev/null 2>&1; _rc=$?
    _k=$(tr "\n" , < "$DATADIR/killed")
    printf "%s|%s" "$_rc" "$_k"
')
[ "$OUT" = "0|999991,999992," ] && ok "PID 文件未发布时可用锁目录 PID+starttime 停止守护实例" || bad "锁记录 PID 回退：[$OUT]"

# ---- 43. capture_all 失败时启动必须中止，不能启动守护或写调度节点 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    _node="$W0/hispeed_load"; _orig=$(read_node "$_node")
    capture_all() { return 1; }
    printf "%s\n" 100 > "$BL"; printf "%s\n" On > "$SYS/class/drm/card0-DSI-1/dpms"
    sf_start 1 >/dev/null 2>&1; _rc=$?
    [ -s "$APPLIED" ] && _ap=1 || _ap=0
    [ -f "$SUPIDF" ] && _sup=1 || _sup=0
    printf "%s|%s|%s|%s" "$_rc" "$_ap" "$_sup" "$(read_node "$_node")"
')
[ "$OUT" = "1|0|0|90" ] && ok "快照采集失败时启动中止且不拉起守护/不登记写入" || bad "capture 失败启动门禁：[$OUT]"

# ---- 44. 初始档位部分写入后返回失败时，按归属记录回滚 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    _node="$W0/hispeed_load"; _orig=$(read_node "$_node")
    printf "%s\n" 100 > "$BL"; printf "%s\n" On > "$SYS/class/drm/card0-DSI-1/dpms"
    apply_on() { printf "%s\n" called > "$DATADIR/apply_called"; set_val "$W0/hispeed_load" 78; return 1; }
    _screen=$(screen_state)
    sf_start 1 >/dev/null 2>&1; _rc=$?
    _after=$(read_node "$_node")
    [ -f "$DATADIR/apply_called" ] && _called=1 || _called=0
    printf "%s|%s|%s|%s|%s" "$_rc" "$_screen" "$_called" "$([ "$_after" = "$_orig" ] && echo restored || echo changed)" "$([ -f "$SUPIDF" ] && echo started || echo absent)"
')
[ "$OUT" = "1|1|1|restored|absent" ] && ok "初始档位部分写入失败后安全回滚且不启动 supervisor" || bad "初始应用失败回滚：[$OUT]"

# ---- 45. Supervisor 启动失败时停止启动事务并回滚初始写入 ----
_SUPERVISOR_BACKUP="$MODROOT/bin/supervisor.sh"
cp "$_SUPERVISOR_BACKUP" "$T/supervisor.good"
printf '#!/system/bin/sh\nexit 1\n' > "$_SUPERVISOR_BACKUP"
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    _orig=$(read_node "$W0/hispeed_load")
    sf_start 1 >/dev/null 2>&1; _rc=$?
    _after=$(read_node "$W0/hispeed_load")
    printf "%s|%s|%s|%s" "$_rc" "$([ "$_after" = "$_orig" ] && echo restored || echo changed)" "$([ -s "$APPLIED" ] && echo retained || echo empty)" "$(read_node "$STOPF" 2>/dev/null)"
')
cp "$T/supervisor.good" "$_SUPERVISOR_BACKUP"
[ "$OUT" = "1|restored|empty|1" ] && ok "Supervisor 启动失败后恢复节点、清空已完成记录并保持停止态" || bad "Supervisor 启动失败回滚：[$OUT]"

# ---- 46. 停止标记写入失败时不得恢复/清空快照，也不得报告成功 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    capture_all
    _orig=$(read_node "$W0/hispeed_load")
    apply_game >/dev/null 2>&1
    rm -f "$STOPF"; mkdir "$STOPF"
    sf_stop >/dev/null 2>&1; _bad_rc=$?
    _kept=0; [ -s "$APPLIED" ] && _kept=1
    rmdir "$STOPF"
    sf_stop >/dev/null 2>&1; _good_rc=$?
    _after=$(read_node "$W0/hispeed_load")
    printf "%s|%s|%s|%s" "$_bad_rc" "$_kept" "$_good_rc" "$([ "$_after" = "$_orig" ] && echo restored || echo changed)"
')
[ "$OUT" = "1|1|0|restored" ] && ok "停止标记写入失败时保留快照并返回失败，修复后可重试恢复" || bad "stop 标记故障注入：[$OUT]"

# ---- 47. 系统分区写入静态守卫：运行时脚本不得出现分区写入目标 ----
GUARD=ok
for _gf in bin/core.sh bin/daemon.sh bin/supervisor.sh service.sh post-fs-data.sh action.sh uninstall.sh scripts/package.sh; do
    [ -f "$HERE/../$_gf" ] || continue
    grep -Eq '/dev/block|by-name|init_boot|fastboot|dd if=|dd of=/dev|mke2fs|flash_image|/odm/|update_engine' "$HERE/../$_gf" && GUARD="hit:$_gf"
done
[ "$GUARD" = ok ] && ok "运行时脚本无 boot/init_boot/system 等分区写入目标" || bad "分区写入守卫：[$GUARD]"


# ---- 48. M1：无属主记录的陈旧 reap gate 可恢复，新鲜 gate 必须保留 ----
rm -rf "$DATA/profile.lock.reap"
mkdir -p "$DATA/profile.lock.reap"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
OUT=$(run '
    rm -f "$PIDF" "$SUPIDF"
    recover_stale_reap_gates; _rc=$?
    printf "%s|%s" "$_rc" "$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)"
')
[ "$OUT" = "0|gone" ] && ok "无 pid 记录的陈旧 reap gate 经时限协议恢复（M1）" || bad "陈旧无主 gate 恢复：[$OUT]"
mkdir -p "$DATA/profile.lock.reap"
OUT=$(run '
    recover_stale_reap_gates; _rc=$?
    printf "%s|%s" "$_rc" "$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)"
')
[ "$OUT" = "1|kept" ] && ok "新鲜的无 pid 记录 gate 不得按时限回收（fail-closed）" || bad "新鲜无主 gate 保留：[$OUT]"
rm -rf "$DATA/profile.lock.reap"

# ---- 49. reap gate 属主记录矩阵：损坏可恢复、PID 复用可证明、活属主必保留 ----
sleep 120 & _LIVE=$!
_LIVE_START=$(awk '{print $22}' "/proc/$_LIVE/stat" 2>/dev/null)
_gate_case() {
    OUT=$(run '
        PROC=/proc; export SF_PROC=/proc
        recover_stale_reap_gate "$PROFILE_LOCK.reap" >/dev/null 2>&1; _rc=$?
        printf "%s|%s" "$_rc" "$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)"
    ')
    printf '%s' "$OUT"
}
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf 'garbage\n' > "$DATA/profile.lock.reap/pid"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
_r1=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '424242\n' > "$DATA/profile.lock.reap/pid"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
_r2=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_LIVE" "999999999" > "$DATA/profile.lock.reap/pid"
_r3=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_LIVE" "$_LIVE_START" > "$DATA/profile.lock.reap/pid"
_r4=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"
kill "$_LIVE" 2>/dev/null; wait "$_LIVE" 2>/dev/null
[ "$_r1|$_r2|$_r3|$_r4" = "0|gone|0|gone|0|gone|1|kept" ] && ok "gate 记录矩阵：损坏/无 starttime 陈旧可恢复，PID 复用可证明，活属主必保留" || bad "gate 记录矩阵：[$_r1|$_r2|$_r3|$_r4]"

# ---- 50. A4：unlock_profile 必须 PID+starttime 双校验 ----
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -rf "$PROFILE_LOCK"
    lock_profile >/dev/null 2>&1 || exit 9
    _self_start=$(proc_start_time $$)
    printf "%s %s\n" "$$" "999999999" > "$PROFILE_LOCK/pid"
    unlock_profile
    _wrong=$([ -d "$PROFILE_LOCK" ] && echo kept || echo gone)
    printf "%s %s\n" "$$" "$_self_start" > "$PROFILE_LOCK/pid"
    unlock_profile
    _right=$([ -d "$PROFILE_LOCK" ] && echo kept || echo gone)
    lock_profile >/dev/null 2>&1 || exit 9
    printf "garbage\n" > "$PROFILE_LOCK/pid"
    unlock_profile
    _corrupt=$([ -d "$PROFILE_LOCK" ] && echo kept || echo gone)
    rm -rf "$PROFILE_LOCK"
    printf "%s|%s|%s" "$_wrong" "$_right" "$_corrupt"
')
[ "$OUT" = "kept|gone|kept" ] && ok "unlock_profile：starttime 不符/记录损坏不解锁，双校验一致才解锁（A4）" || bad "unlock 身份校验：[$OUT]"

# ---- 51. 并发 start/start/stop：session 锁串行化，最终状态必须自洽 ----
run '
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    printf "%s\n" 100 > "$BL"; printf "%s\n" On > "$SYS/class/drm/card0-DSI-1/dpms"
'
( run 'PROC=/proc; export SF_PROC=/proc; sf_start 1 >/dev/null 2>&1; printf "%s" "$?"' > "$T/r51a" ) &
( run 'PROC=/proc; export SF_PROC=/proc; sf_start 1 >/dev/null 2>&1; printf "%s" "$?"' > "$T/r51b" ) &
( run 'PROC=/proc; export SF_PROC=/proc; sf_stop >/dev/null 2>&1; printf "%s" "$?"' > "$T/r51c" ) &
wait
_rcs="$(cat "$T/r51a" 2>/dev/null)$(cat "$T/r51b" 2>/dev/null)$(cat "$T/r51c" 2>/dev/null)"
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    _s=$(read_node "$STOPF" 2>/dev/null)
    _l=$([ -d "$SESSION_LOCK" ] && echo 1 || echo 0)
    _d=$([ -s "$DEF" ] && echo 1 || echo 0)
    _p=$([ -f "$SUPIDF" ] && echo 1 || echo 0)
    printf "%s|%s|%s|%s" "$_s" "$_l" "$_d" "$_p"
')
# 返回码语义（rc6 探针三轮实测后定稿，不再只验“全是数字”）：stop 恒为 0；
# 两个 start 至多一个以 1 干净失败（竞争落败并完成回滚），不得双双失败、
# 不得出现其它返回码；同时最终状态必须自洽（started/stopped 二选一）。
case "$_rcs" in
    000|010|100)
        case "$OUT" in
            "0|0|1|1") _state=started ;;
            "1|0|0|0") _state=stopped ;;
            *) _state="incoherent:$OUT" ;;
        esac ;;
    *) _state="badrc:$_rcs" ;;
esac
run 'PROC=/proc; export SF_PROC=/proc; sf_stop >/dev/null 2>&1'
case "$_state" in
    started|stopped)
        case "$_rcs" in
            010|100)
                if grep -E '遗留回收门禁未能安全恢复，拒绝启动|生命周期操作正在执行' "$DATA/smoothflow.log" >/dev/null 2>&1; then
                    ok "并发启停拒绝原因有门禁/生命周期日志证据"
                else
                    bad "并发启停出现单个 start 返回 1，但日志缺少门禁拒绝证据"
                fi ;;
        esac
        ok "并发启停返回码合规（$_rcs）且状态自洽（$_state）、无 session 锁泄漏" ;;
    *) bad "并发启停一致性：[$_state]" ;;
esac

# ---- 52. uninstall：恢复失败时中止且保留数据，成功时先恢复再归档 ----
UNINST="$T/uninst"
mkdir -p "$UNINST"
cp "$HERE/../uninstall.sh" "$UNINST/"
cp -r "$MODROOT/bin" "$UNINST/"
run '
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    capture_all
    apply_game >/dev/null 2>&1
'
run 'rm -f "$STOPF"; mkdir "$STOPF"'
SF_TEST_MODE=1 SF_SYS=$SYS SF_PROC=/proc SF_CG=$CG SF_DATADIR=$DATA SF_TRASH=$TRASH SF_GETPROP="$T/getprop" sh "$UNINST/uninstall.sh" >/dev/null 2>&1; _neg_rc=$?
_neg_data=$([ -d "$DATA" ] && echo kept || echo gone)
_neg_node=$(IFS= read -r _v < "$P0/walt/hispeed_load"; printf '%s' "$_v")
run 'rmdir "$STOPF"'
SF_TEST_MODE=1 SF_SYS=$SYS SF_PROC=/proc SF_CG=$CG SF_DATADIR=$DATA SF_TRASH=$TRASH SF_GETPROP="$T/getprop" sh "$UNINST/uninstall.sh" >/dev/null 2>&1; _pos_rc=$?
_pos_data=$([ -d "$DATA" ] && echo kept || echo gone)
_pos_node=$(IFS= read -r _v < "$P0/walt/hispeed_load"; printf '%s' "$_v")
_trash_n=$(ls "$TRASH" 2>/dev/null | wc -l)
if [ "$_neg_rc" != 0 ] && [ "$_neg_data" = kept ] && [ "$_neg_node" = 78 ] && [ "$_pos_rc" = 0 ] && [ "$_pos_data" = gone ] && [ "$_pos_node" = 90 ] && [ "$_trash_n" -ge 1 ]; then
    ok "uninstall：停止标记不可写时中止卸载并保留快照，正常时先恢复节点再归档数据"
else
    bad "uninstall 恢复路径：[neg=$_neg_rc/$_neg_data/$_neg_node pos=$_pos_rc/$_pos_data/$_pos_node trash=$_trash_n]"
fi

# ---- 53. M1 真实注入：gate 创建后、pid 发布前强杀进程，sf_start 必须越过遗留 gate ----
mkdir -p "$DATA"
printf 'SM8850P\n' > "$DATA/mock_soc"
printf 'OPD2513\n' > "$DATA/mock_device"
rm -rf "$DATA/profile.lock.reap"
sh -c 'mkdir "$1"; sleep 30' _ "$DATA/profile.lock.reap" & _HOLDER=$!
sleep 0.5
kill -9 "$_HOLDER" 2>/dev/null; wait "$_HOLDER" 2>/dev/null
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    rm -f "$PIDF" "$SUPIDF" "$DEF" "$APPLIED" "$STOPF"
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DAEMON_LOCK" "$SESSION_LOCK"
    printf "%s\n" 100 > "$BL"; printf "%s\n" On > "$SYS/class/drm/card0-DSI-1/dpms"
    sf_start 1 >/dev/null 2>&1; _rc=$?
    _g=$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)
    sf_stop >/dev/null 2>&1
    printf "%s|%s" "$_rc" "$_g"
')
[ "$OUT" = "0|gone" ] && ok "持锁者发布 pid 前被强杀留下的无主 gate 不再锁死启动（M1 端到端）" || bad "M1 强杀注入端到端：[$OUT]"

# ---- 54. M1-A：观察窗内或改名后出现迟到属主记录，无主 gate 必须还原保留 ----
# 54a：记录在 1 秒观察窗内出现（模拟属主被暂停后恢复发布）——mtime 与记录
# 内容双重变化必须被任一守卫拦下，gate 与记录一并保留。
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    sleep 120 & _P=$!
    _S=$(proc_start_time $_P 2>/dev/null)
    ( sleep 0.3; printf "%s %s\n" "$_P" "$_S" > "$PROFILE_LOCK.reap/pid" ) &
    recover_stale_reap_gate "$PROFILE_LOCK.reap" >/dev/null 2>&1; _rc=$?
    kill "$_P" 2>/dev/null
    _g=$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)
    _rec=$(read_node "$PROFILE_LOCK.reap/pid" 2>/dev/null)
    _recok=$([ "$_rec" = "$_P $_S" ] && echo ok || echo bad)
    printf "%s|%s|%s" "$_rc" "$_g" "$_recok"
')
rm -rf "$DATA/profile.lock.reap"
[ "$OUT" = "1|kept|ok" ] && ok "观察窗内出现迟到属主记录时无主 gate 保留不删（M1-A 观察窗）" || bad "M1-A 观察窗注入：[$OUT]"
# 54b：以函数桩包装 mv，在隔离改名完成后、删除前向隔离副本植入一条可解析
# 属主记录（确定性复现“末次检查与改名之间发布记录”的竞态结果）——改名后
# 复查必须发现记录并把 gate 原样还原，不得删除。
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
OUT=$(run '
    PROC=/proc; export SF_PROC=/proc
    sleep 120 & _P=$!
    _S=$(proc_start_time $_P 2>/dev/null)
    mv() {
        command mv "$@" || return $?
        for _a; do _dst=$_a; done
        case "$_dst" in *.stale.*) printf "%s %s\n" "$_P" "$_S" > "$_dst/pid" 2>/dev/null ;; esac
        return 0
    }
    recover_stale_reap_gate "$PROFILE_LOCK.reap" >/dev/null 2>&1; _rc=$?
    kill "$_P" 2>/dev/null
    _g=$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)
    _rec=$(read_node "$PROFILE_LOCK.reap/pid" 2>/dev/null)
    _recok=$([ "$_rec" = "$_P $_S" ] && echo ok || echo bad)
    _left=$(ls -d "$PROFILE_LOCK.reap".stale.* 2>/dev/null | wc -l)
    printf "%s|%s|%s|%s" "$_rc" "$_g" "$_recok" "$_left"
')
rm -rf "$DATA/profile.lock.reap"
[ "$OUT" = "1|kept|ok|0" ] && ok "改名后出现属主记录时隔离副本必须还原不删（M1-A 改名后复查）" || bad "M1-A 改名后注入：[$OUT]"

# ---- 55. M1-B：非数字 starttime 不得冒充死亡证明；僵尸/死 PID 可回收 ----
sleep 600 & _LIVE55=$!
_LIVE55_START=$(awk '{print $22}' "/proc/$_LIVE55/stat" 2>/dev/null)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_LIVE55" "notanumber" > "$DATA/profile.lock.reap/pid"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
_b1=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_LIVE55" "999999999" > "$DATA/profile.lock.reap/pid"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
_b2=$(_gate_case)
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_LIVE55" "$_LIVE55_START" > "$DATA/profile.lock.reap/pid"
_b3=$(_gate_case)
# 死 PID 由真实短命子进程产生并 wait 回收，不依赖固定 PID 常量。
sleep 0.05 & _DEAD55=$!
wait "$_DEAD55" 2>/dev/null
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_DEAD55" "notanumber" > "$DATA/profile.lock.reap/pid"
touch -d "@$(( $(date +%s) - 120 ))" "$DATA/profile.lock.reap"
_b4=$(_gate_case)
# 僵尸 PID + 非数字 starttime：严格启动恢复判定应以 Z 状态优先于格式校验。
_ZPID55=424241
mkdir -p "$PROC/$_ZPID55"
printf '%s (zombie) Z 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12345\n' "$_ZPID55" > "$PROC/$_ZPID55/stat"
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_ZPID55" "notanumber" > "$DATA/profile.lock.reap/pid"
run 'reap_gate_owner_stale "$PROFILE_LOCK.reap" >/dev/null 2>&1; printf "%s" "$?"' > "$T/r55gate_zombie"
_gz=$(cat "$T/r55gate_zombie")
rm -rf "$DATA/profile.lock.reap"; mkdir -p "$DATA/profile.lock.reap"
printf '%s %s\n' "$_ZPID55" "notanumber" > "$DATA/profile.lock.reap/pid"
run 'reap_gate_stale "$PROFILE_LOCK.reap" >/dev/null 2>&1; _rc=$?; printf "%s|%s" "$_rc" "$([ -d "$PROFILE_LOCK.reap" ] && echo kept || echo gone)"' > "$T/r55lock_zombie"
_lz=$(cat "$T/r55lock_zombie")
rm -rf "$DATA/profile.lock.reap" "$PROC/$_ZPID55"
kill "$_LIVE55" 2>/dev/null; wait "$_LIVE55" 2>/dev/null
[ "$_b1|$_b2|$_b3|$_b4|$_gz|$_lz" = "1|kept|0|gone|1|kept|0|gone|0|0|gone" ] && ok "非数字 starttime：活属主保留、死 PID 与僵尸 PID 均可回收（严格 gate + lock gate）" || bad "M1-B 记录矩阵：[$_b1|$_b2|$_b3|$_b4|$_gz|$_lz]"

# ---- 56. 发布守卫负向：自身 stat 不可读时三类锁均不得发布 ----
OUT=$(run '
    rm -rf "$PROFILE_LOCK" "$SUPLOCK" "$DATA/reap-guard.lock" "$DATA/reap-guard.lock.reap"
    rm -f "$PROC/$$/stat"
    lock_profile >/dev/null 2>&1; _lp=$?
    acquire_supervisor_lock >/dev/null 2>&1; _asl=$?
    reap_lock_dir "$DATA/reap-guard.lock" >/dev/null 2>&1; _rld=$?
    _profile=$([ -d "$PROFILE_LOCK" ] && echo dir || echo clean)
    _super=$([ -d "$SUPLOCK" ] && echo dir || echo clean)
    _reap=$([ -d "$DATA/reap-guard.lock.reap" ] && echo dir || echo clean)
    _pid=$([ -e "$PROFILE_LOCK/pid" ] || [ -e "$SUPLOCK/pid" ] || [ -e "$DATA/reap-guard.lock.reap/pid" ] && echo present || echo absent)
    printf "%s|%s|%s|%s|%s|%s|%s" "$_lp" "$_asl" "$_rld" "$_profile" "$_super" "$_reap" "$_pid"
')
[ "$OUT" = "1|1|1|clean|clean|clean|absent" ] && ok "自身 stat 不可读时 profile/supervisor/reap 锁均拒绝发布并清理空目录" || bad "发布守卫负向：[$OUT]"

printf '\n通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
