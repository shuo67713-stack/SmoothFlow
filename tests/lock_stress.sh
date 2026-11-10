#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# SmoothFlow lock stress test: uses real /proc, temporary data only; never writes /sys.
HERE=$(cd "${0%/*}" && pwd)
CORE=$HERE/../bin/core.sh
T=${SF_STRESS_DIR:-${TMPDIR:-/tmp}/sf-lock-stress.$$}
export SF_STRESS_DIR="$T"
mkdir -p "$T/data" "$T/sys" "$T/cg"
export SF_DATADIR="$T/data" SF_SYS="$T/sys" SF_CG="$T/cg" SF_PROC=/proc SF_TRASH="$T/trash"
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

run_round() {
    _mode=$1
    if [ "$_mode" = profile ]; then _lock="$T/data/profile.lock"; else _lock="$T/data/supervisor.lock"; fi
    rm -rf "$_lock" "$_lock.reap" "$T/inside"
    mkdir "$_lock" || return 1
    printf '99999999 1\n' > "$_lock/pid"
    sh "$0" --worker "$_mode" & _a=$!
    sh "$0" --worker "$_mode" & _b=$!
    wait "$_a"; _ra=$?
    wait "$_b"; _rb=$?
    [ "$_ra" = 0 ] && [ "$_rb" = 0 ] || return 1
    [ ! -e "$T/collision" ] || return 1
    [ ! -d "$_lock" ] || return 1
    [ ! -d "$_lock.reap" ] || return 1
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
