#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/tmp/CodexPetLimitRings.app}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
MODULE_CACHE="${CODEX_PET_LIMIT_RINGS_MODULE_CACHE:-${TMPDIR:-/tmp}/codex-pet-limit-rings-module-cache}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$MODULE_CACHE"
cp "$ROOT/tools/CodexPetLimitRings-Info.plist" "$APP/Contents/Info.plist"
swiftc -module-cache-path "$MODULE_CACHE" "$ROOT/tools/codex-pet-limit-rings.swift" -o "$BIN" -framework AppKit -framework QuartzCore -lsqlite3

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "$APP"
