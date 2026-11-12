#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# SmoothFlow lock stress test: uses real /proc, temporary data only; never writes /sys.
HERE=$(cd "${0%/*}" && pwd)
if [ -f "$HERE/core.sh" ]; then CORE=$HERE/core.sh; else CORE=$HERE/../bin/core.sh; fi
T=${SF_STRESS_DIR:-${TMPDIR:-/tmp}/sf-lock-stress.$$}
export SF_STRESS_DIR="$T"
mkdir -p "$T/data" "$T/sys" "$T/cg"
export SF_TEST_MODE=1 SF_DATADIR="$T/data" SF_SYS="$T/sys" SF_CG="$T/cg" SF_PROC=/proc SF_TRASH="$T/trash"
FAIL=0
ROUNDS=${ROUNDS:-20}

worker() {
    _mode=$1
    . "$CORE"
    if [ "$_mode" = profile ]; then
        lock_profile || exit 10
    else
        acquire_supervisor_lock || exit 10
    fi
    if ! mkdir "$T/inside" 2>/dev/null; then
        printf 'collision %s %s\n' "$_mode" "$$" >> "$T/collision"
        if [ "$_mode" = profile ]; then unlock_profile; else release_supervisor_lock; fi
        exit 11
    fi
    sleep 0.02
    rmdir "$T/inside" 2>/dev/null
    if [ "$_mode" = profile ]; then unlock_profile; else release_supervisor_lock; fi
}

if [ "${1:-}" = "--worker" ]; then
    worker "$2"
    exit $?
fi

# Parent needs the same proc identity helper to seed a genuinely live gate owner.
. "$CORE"

run_round() {
    _mode=$1
    if [ "$_mode" = profile ]; then _lock="$T/data/profile.lock"; else _lock="$T/data/supervisor.lock"; fi
    rm -rf "$_lock" "$_lock.reap" "$T/inside" "$T/collision"
    mkdir "$_lock" || return 1
    printf '99999999 1\n' > "$_lock/pid"
    sh "$0" --worker "$_mode" & _a=$!
    sh "$0" --worker "$_mode" & _b=$!
    _ticks=0
    while { kill -0 "$_a" 2>/dev/null || kill -0 "$_b" 2>/dev/null; } && [ "$_ticks" -lt 150 ]; do
        sleep 0.1
        _ticks=$((_ticks + 1))
    done
    if kill -0 "$_a" 2>/dev/null || kill -0 "$_b" 2>/dev/null; then
        kill -9 "$_a" "$_b" 2>/dev/null || :
        wait "$_a" 2>/dev/null || :
        wait "$_b" 2>/dev/null || :
        echo "worker timeout: $_mode" >&2
        return 1
    fi
    wait "$_a"; _ra=$?
    wait "$_b"; _rb=$?
    [ "$_ra" = 0 ] && [ "$_rb" = 0 ] || return 1
    [ ! -e "$T/collision" ] || return 1
    [ ! -d "$_lock" ] || return 1
    [ ! -d "$_lock.reap" ] || return 1

    # 空锁目录：模拟 mkdir 后、pid 文件发布前崩溃（mtime 超过兜底阈值）。
    mkdir "$_lock" || return 1
    touch -t 200001010000 "$_lock" 2>/dev/null || :
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock" ] || return 1

    # 预置无 PID 的旧 gate：mtime 兜底应允许等待者回收孤儿门。
    mkdir "$_lock.reap" 2>/dev/null || :
    touch -t 200001010000 "$_lock.reap" 2>/dev/null || :
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock.reap" ] || return 1

    # 带 PID 的孤儿 gate：PID 不存在时也必须被识别为陈旧。
    mkdir "$_lock.reap" || return 1
    printf '99999999 1\n' > "$_lock.reap/pid"
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock.reap" ] || return 1

    # 带活 PID 的 gate：属主仍是本测试进程，竞争者必须 fail-closed。
    mkdir "$_lock.reap" || return 1
    _live_start=$(proc_start_time $$ 2>/dev/null) || return 1
    printf '%s %s\n' "$$" "$_live_start" > "$_lock.reap/pid"
    reap_gate_stale "$_lock.reap" >/dev/null 2>&1
    _live_rc=$?
    [ "$_live_rc" -ne 0 ] || return 1
    [ -d "$_lock.reap" ] || return 1
    rm -rf "$_lock.reap"
}

n=0
while [ "$n" -lt "$ROUNDS" ]; do
    run_round profile || { echo "FAIL profile lock round=$n"; FAIL=1; break; }
    run_round supervisor || { echo "FAIL supervisor lock round=$n"; FAIL=1; break; }
    n=$((n + 1))
done
rm -rf "$T"
if [ "$FAIL" = 0 ]; then echo "PASS lock stress: $((ROUNDS * 2)) dual-process stale-lock rounds"; exit 0; fi
exit 1
