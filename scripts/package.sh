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

copy_item() {
    src=$1
    [ -e "$ROOT/$src" ] || {
        printf 'Missing required package path: %s\n' "$src" >&2
        exit 1
    }
    cp -R "$ROOT/$src" "$TMP/"
}

for item in module.prop post-fs-data.sh service.sh action.sh uninstall.sh \
            config.example.sh README.md CHANGELOG.md RELEASE_NOTES_v5.0.4.md LICENSE NOTICE.md bin tests webroot; do
    copy_item "$item"
done

# Runtime entrypoints must remain executable in the ZIP.
chmod 755 "$TMP/post-fs-data.sh" "$TMP/service.sh" "$TMP/action.sh" "$TMP/uninstall.sh" \
          "$TMP/bin/core.sh" "$TMP/bin/daemon.sh" "$TMP/bin/supervisor.sh" "$TMP/tests/selftest.sh" "$TMP/tests/lock_stress.sh"
chmod 644 "$TMP/config.example.sh"

ZIP="$OUT/SmoothFlow_5.0.4_OPD2513.zip"
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
