#!/usr/bin/env bash
# 由 apps/desktop/Resources/AppIcon.svg 生成 AppIcon.icns（16–512 的 @1x/@2x，含 1024）。
# 只在改了图标源文件时手动跑一次，生成的 .icns 提交进 git；打包（package-desktop.sh）直接用它，不在构建时生成。
# 需要 rsvg-convert（brew install librsvg）和系统自带的 iconutil。
set -euo pipefail
RES="$(cd "$(dirname "$0")/.." && pwd)/apps/desktop/Resources"
command -v rsvg-convert >/dev/null || { echo "✗ 没有 rsvg-convert：brew install librsvg" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
set_dir="$tmp/AppIcon.iconset"; mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" "$RES/AppIcon.svg" -o "$set_dir/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) "$RES/AppIcon.svg" -o "$set_dir/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set_dir" -o "$RES/AppIcon.icns"
echo "▸ 已生成 $RES/AppIcon.icns"
