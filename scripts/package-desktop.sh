#!/usr/bin/env bash
# 项目基线 · 桌面应用的打包钩子（技术选型例外：原生 Swift，不用 Electron）。
# scripts/release-desktop.sh build 在 tag 的内容里调用它：
#
#   scripts/package-desktop.sh <版本号 X.Y.Z> <tag desktop-vX.Y.Z> <输出目录>
#
# 本机自测打包：scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app
#
# 产出 <输出目录>/1Melon.app（ad-hoc 签名）。版本号构建时注入，不改源码：
#   Info.plist 的 CFBundleShortVersionString = X.Y.Z，CFBundleVersion = tag。
# dmg、版本清单、上传、GitHub Release 由 release-desktop.sh 统一做，这里不管。
set -euo pipefail
VER="${1:?版本号}"; TAG="${2:?tag}"; OUT="${3:?输出目录}"
PRODUCT=1Melon
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/apps/desktop"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ 版本号不合法：${VER}（要 X.Y.Z）" >&2; exit 1; }

echo "▸ 编译 MelonApp（release，arm64）"
swift build -c release --arch arm64 --package-path "$PKG" --product MelonApp
BIN_DIR="$(swift build -c release --arch arm64 --package-path "$PKG" --show-bin-path)"
[[ -x "$BIN_DIR/MelonApp" ]] || { echo "✗ 没有编译出 $BIN_DIR/MelonApp" >&2; exit 1; }

APP="$OUT/$PRODUCT.app"
echo "▸ 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MelonApp" "$APP/Contents/MacOS/$PRODUCT"
# SwiftPM 为带资源的模块生成的 *.bundle 也要带上（现在没有，加了资源后自动生效）
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
cp "$PKG/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VER" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$TAG" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "▸ ad-hoc 签名（开启 hardened runtime）"
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"
echo "▸ 产物：${APP}（版本 ${VER}，${TAG}）"
