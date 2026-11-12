#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-"$ROOT/dist"}
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/smoothflow-package.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

copy_file() {
    src=$1
    [ -f "$ROOT/$src" ] || { printf 'Missing required package file: %s\n' "$src" >&2; exit 1; }
    mkdir -p "$TMP/$(dirname "$src")"
    cp "$ROOT/$src" "$TMP/$src"
}

# 显式文件清单：不递归复制目录，避免草稿/备份/临时文件进入发布包。
for item in module.prop post-fs-data.sh service.sh action.sh uninstall.sh \
            config.example.sh README.md CHANGELOG.md LICENSE NOTICE.md PATCH3_SECURITY_FIXES.md \
            bin/core.sh bin/daemon.sh bin/supervisor.sh \
            tests/selftest.sh tests/lock_stress.sh webroot/index.html; do
    copy_file "$item"
done

# 发布构建固化生产路径，彻底移除 SF_* 测试环境覆盖入口。
# 源码树仍保留 SF_TEST_MODE 分支供隔离测试使用。
# 隔离测试专用 core 放在 tests/，任何运行时入口均不会引用它。
cp "$ROOT/bin/core.sh" "$TMP/tests/core.sh"
chmod 644 "$TMP/tests/core.sh"
sed -i '/^if \[ "${SF_TEST_MODE:-0}" = 1 \]; then$/,/^fi$/c\
SYS=/sys\
PROC=/proc\
CG=/dev/cpuctl\
DATADIR=/data/adb/smoothflow\
TRASH=/data/adb/smoothflow_trash' "$TMP/bin/core.sh"
sed -i 's/if \[ "${SF_TEST_MODE:-0}" = 1 \]; then GETPROP=${SF_GETPROP:-getprop}; else GETPROP=getprop; fi/GETPROP=getprop/' "$TMP/bin/core.sh"

# Fail closed: test-only environment overrides must never ship in the release core.
if grep -Eq 'SF_TEST_MODE|SF_SYS|SF_PROC|SF_CG|SF_DATADIR|SF_TRASH|SF_GETPROP' "$TMP/bin/core.sh"; then
    printf 'Test-only environment override leaked into release core.\n' >&2
    exit 1
fi

# Runtime entrypoints must remain executable in the ZIP.
chmod 755 "$TMP/post-fs-data.sh" "$TMP/service.sh" "$TMP/action.sh" "$TMP/uninstall.sh" \
          "$TMP/bin/core.sh" "$TMP/bin/daemon.sh" "$TMP/bin/supervisor.sh" "$TMP/tests/selftest.sh" "$TMP/tests/lock_stress.sh"
chmod 644 "$TMP/config.example.sh"

ZIP="$OUT/SmoothFlow_5.0.6-rc1_OPD2513.zip"
rm -f "$ZIP" "$ZIP.sha256"
(
    cd "$TMP"
    zip -X -qr "$ZIP" .
)
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
else
    printf 'sha256sum is required to create the release checksum.\n' >&2
    exit 1
fi

printf 'Created: %s\n' "$ZIP"
printf 'Checksum: %s\n' "$ZIP.sha256"
