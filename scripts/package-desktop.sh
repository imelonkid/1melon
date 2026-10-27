#!/usr/bin/env bash
# 项目基线 · 桌面应用的打包钩子（技术选型例外：原生 Swift，不用 Electron）。
# scripts/release-desktop.sh build 在 tag 的内容里调用它：
#
#   scripts/package-desktop.sh <版本号 X.Y.Z> <tag desktop-vX.Y.Z> <输出目录>
#
# 本机自测打包：scripts/package-desktop.sh 0.0.0 dev dist && open dist/1Melon.app
#
# 产出 <输出目录>/1Melon.app。版本号构建时注入，不改源码：
#   Info.plist 的 CFBundleShortVersionString = X.Y.Z，CFBundleVersion = tag。
# dmg、版本清单、上传、GitHub Release 由 release-desktop.sh 统一做，这里不管。
#
# 签名（环境变量，不写死在脚本里）：
#   SIGN_IDENTITY         不设：ad-hoc 签名，不带权限声明。这样的包没有钥匙串权限，Touch ID 解锁不可用（只能输主密码）
#                         设了：用这张证书签，如 "Apple Development"（本机自测）、"Developer ID Application"（正式发布）
#   PROVISIONING_PROFILE  描述文件路径。不设就在 Xcode 的描述文件目录里，按 bundle id 找没过期、最晚过期的那份
# 带证书签名时：描述文件放进 Contents/embedded.provisionprofile，权限声明只有 App 标识、Team ID 和
# 钥匙串访问组 <TeamID>.<bundle id>（Touch ID 解锁用的钥匙串条目），Team ID 从描述文件里读。
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

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ ad-hoc 签名（开启 hardened runtime；没有钥匙串权限，Touch ID 不可用）"
  codesign --force --options runtime --sign - "$APP"
else
  BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # 描述文件里的 App 标识是 <TeamID>.<bundle id>；ExpirationDate 是 ISO 8601，按字符串比较就是按时间比较
  profile_matches() {   # profile_matches <描述文件> → 打印「过期时间 路径」
    security cms -D -i "$1" > "$tmp/p.plist" 2>/dev/null || return 1
    local app_id exp
    app_id="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw "$tmp/p.plist" 2>/dev/null)" || return 1
    exp="$(plutil -extract ExpirationDate raw "$tmp/p.plist" 2>/dev/null)" || return 1
    [[ "${app_id#*.}" == "$BUNDLE_ID" && "$exp" > "$NOW" ]] && echo "$exp $1"
  }
  if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
    PROVISIONING_PROFILE="$(
      for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile \
               "$HOME/Library/MobileDevice/Provisioning Profiles/"*.provisionprofile; do
        [[ -f "$f" ]] && profile_matches "$f" || true
      done | sort -r | head -1 | cut -d' ' -f2-
    )"
    [[ -n "$PROVISIONING_PROFILE" ]] || { echo "✗ 没找到 $BUNDLE_ID 的有效描述文件：在 Xcode 里重新生成（个人团队的 7 天就过期），或用 PROVISIONING_PROFILE 指定" >&2; exit 1; }
  fi
  [[ -n "$(profile_matches "$PROVISIONING_PROFILE")" ]] || { echo "✗ 描述文件不是 $BUNDLE_ID 的，或者已经过期：$PROVISIONING_PROFILE" >&2; exit 1; }
  security cms -D -i "$PROVISIONING_PROFILE" > "$tmp/p.plist"
  TEAM_ID="$(plutil -extract TeamIdentifier.0 raw "$tmp/p.plist")"
  cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  cat > "$tmp/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>$TEAM_ID.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$TEAM_ID</string>
	<key>keychain-access-groups</key>
	<array>
		<string>$TEAM_ID.$BUNDLE_ID</string>
	</array>
</dict>
</plist>
PLIST
  plutil -lint "$tmp/app.entitlements" >/dev/null
  # 正式发布（Developer ID）要带苹果的时间戳，公证才收；本机自测的开发证书不用
  ts=(); [[ "$SIGN_IDENTITY" == Developer\ ID* ]] && ts=(--timestamp)
  echo "▸ 用证书签名：${SIGN_IDENTITY}（Team ${TEAM_ID}，描述文件过期时间 $(plutil -extract ExpirationDate raw "$tmp/p.plist")）"
  codesign --force --options runtime ${ts[@]+"${ts[@]}"} --entitlements "$tmp/app.entitlements" --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "▸ 产物：${APP}（版本 ${VER}，${TAG}）"
