#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${CODEX_PET_LIMIT_RINGS_TMP:-$ROOT/tmp}"
BIN="$TMP_DIR/codex-pet-limit-rings"
APP="$TMP_DIR/CodexPetLimitRings.app"
MODULE_CACHE="${CODEX_PET_LIMIT_RINGS_MODULE_CACHE:-${TMPDIR:-/tmp}/codex-pet-limit-rings-module-cache}"
PREVIEW_SIZE="${CODEX_PET_LIMIT_RINGS_PREVIEW_SIZE:-164}"

mkdir -p "$TMP_DIR" "$MODULE_CACHE"

bash -n "$ROOT"/tools/*.sh

swiftc \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT/tools/codex-pet-limit-rings.swift" \
  -o "$BIN" \
  -framework AppKit \
  -framework QuartzCore \
  -lsqlite3

for style in segmented-pixel classic-glow crt-glow; do
  "$BIN" \
    --preview "$TMP_DIR/limit-rings-$style.png" \
    --size "$PREVIEW_SIZE" \
    --style "$style"
done

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null

if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" diff --check
fi

echo "Codex Pet Limit Rings validation passed"
echo "Preview PNGs: $TMP_DIR/limit-rings-{segmented-pixel,classic-glow,crt-glow}.png"
echo "App bundle: $APP"
