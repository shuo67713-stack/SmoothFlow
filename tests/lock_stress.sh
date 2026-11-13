#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# SmoothFlow lock stress test: uses real /proc and temporary data only; never writes /sys.
HERE=$(cd "${0%/*}" && pwd)
if [ -f "$HERE/core.sh" ]; then CORE=$HERE/core.sh; else CORE=$HERE/../bin/core.sh; fi
T=${SF_STRESS_DIR:-${TMPDIR:-/tmp}/sf-lock-stress.$$}
export SF_STRESS_DIR="$T"
mkdir -p "$T/data" "$T/sys" "$T/cg"
export SF_TEST_MODE=1 SF_DATADIR="$T/data" SF_SYS="$T/sys" SF_CG="$T/cg" SF_PROC=/proc SF_TRASH="$T/trash"
ROUNDS=${ROUNDS:-5}

worker() {
    _mode=$1
    . "$CORE"
    case "$_mode" in
        profile) lock_profile || exit 10 ;;
        supervisor) acquire_supervisor_lock || exit 10 ;;
        daemon) acquire_daemon_lock || exit 10 ;;
        session) acquire_session_lock || exit 10 ;;
        *) exit 12 ;;
    esac
    if ! mkdir "$T/inside" 2>/dev/null; then
        printf 'collision %s %s\n' "$_mode" "$$" >> "$T/collision"
        case "$_mode" in
            profile) unlock_profile ;;
            supervisor) release_supervisor_lock ;;
            daemon) release_daemon_lock ;;
            session) release_session_lock ;;
        esac
        exit 11
    fi
    sleep 0.02
    rmdir "$T/inside" 2>/dev/null
    case "$_mode" in
        profile) unlock_profile ;;
        supervisor) release_supervisor_lock ;;
        daemon) release_daemon_lock ;;
        session) release_session_lock ;;
    esac
}

if [ "${1:-}" = "--worker" ]; then
    worker "$2"
    exit $?
fi

. "$CORE"
lock_path() {
    case "$1" in
        profile) printf '%s\n' "$PROFILE_LOCK" ;;
        supervisor) printf '%s\n' "$SUPLOCK" ;;
        daemon) printf '%s\n' "$DAEMON_LOCK" ;;
        session) printf '%s\n' "$SESSION_LOCK" ;;
    esac
}

run_concurrency() {
    _mode=$1
    _lock=$(lock_path "$_mode")
    rm -rf "$_lock" "$_lock.reap" "$T/inside" "$T/collision"
    sh "$0" --worker "$_mode" & _a=$!
    sh "$0" --worker "$_mode" & _b=$!
    wait "$_a"; _ra=$?
    wait "$_b"; _rb=$?
    [ "$_ra" = 0 ] && [ "$_rb" = 0 ] || return 1
    [ ! -e "$T/collision" ] || return 1
    [ ! -d "$_lock" ] || return 1
    [ ! -d "$_lock.reap" ] || return 1
}

run_stale_recovery() {
    _mode=$1
    _lock=$(lock_path "$_mode")
    rm -rf "$_lock" "$_lock.reap"

    # 有 PID 的陈旧主锁：PID 不存在，应被隔离并回收。
    mkdir "$_lock" || return 1
    printf '99999999 1\n' > "$_lock/pid"
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock" ] || return 1

    # 空主锁目录：模拟 mkdir 后、PID 发布前崩溃；只允许旧 mtime 兜底。
    mkdir "$_lock" || return 1
    touch -t 200001010000 "$_lock" 2>/dev/null || :
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock" ] || return 1

    # 无 PID 的旧 reap gate：profile/supervisor/daemon 仍沿用 30s mtime 兜底。
    mkdir "$_lock.reap" || return 1
    touch -t 200001010000 "$_lock.reap" 2>/dev/null || :
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock.reap" ] || return 1

    # 带死亡 PID+starttime 的孤儿 gate：应安全回收。
    mkdir "$_lock.reap" || return 1
    printf '99999999 1\n' > "$_lock.reap/pid"
    sh "$0" --worker "$_mode" || return 1
    [ ! -d "$_lock.reap" ] || return 1

    # 活 PID gate 必须 fail-closed。
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
    for _mode in profile supervisor daemon session; do
        run_concurrency "$_mode" || { echo "FAIL $_mode concurrency round=$n"; rm -rf "$T"; exit 1; }
    done
    n=$((n + 1))
done
for _mode in profile supervisor daemon; do
    run_stale_recovery "$_mode" || { echo "FAIL $_mode stale recovery"; rm -rf "$T"; exit 1; }
done
# Session gate uses the stricter PID+starttime recovery; this fixture proves no-owner gates stay put.
rm -rf "$SESSION_LOCK" "$SESSION_LOCK.reap"
mkdir "$SESSION_LOCK.reap" || exit 1
recover_stale_reap_gate "$SESSION_LOCK.reap" >/dev/null 2>&1 && { rm -rf "$T"; echo 'FAIL session missing-owner gate was reclaimed'; exit 1; }
[ -d "$SESSION_LOCK.reap" ] || { rm -rf "$T"; echo 'FAIL session missing-owner gate disappeared'; exit 1; }
rm -rf "$T"
echo "PASS lock stress: $((ROUNDS * 4)) dual-process mutual-exclusion rounds plus 15 legacy stale/active lock fixtures and one strict session-gate fixture"
exit 0
