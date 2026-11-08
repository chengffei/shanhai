#!/bin/bash
# 安装最新版山海：
#   curl -fsSL https://raw.githubusercontent.com/chengffei/shanhai/main/install.sh | bash
#
# 用 curl 下载的文件不带隔离标记，打开时不会弹「无法验证开发者」。作为交换，脚本会核对下载内容：
# 发布页公布的 SHA-256、有效的代码签名、预期的 Bundle ID 和开发者团队。
set -euo pipefail

[ "$(uname -m)" = arm64 ] || { echo "错误：山海需要 Apple 芯片的 Mac" >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo "错误：山海需要 macOS 26 或更新" >&2; exit 1; }

REPO="chengffei/shanhai"
BUNDLE_ID="io.github.chengffei.shanhai"
TEAM_ID="TWK29JGBQJ"
DEST="${SHANHAI_INSTALL_DIR:-/Applications}"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BASE="https://github.com/$REPO/releases/latest/download"
echo "==> 下载最新版山海（约 130 MB）"
curl -fL --progress-bar "$BASE/Shanhai.zip" -o "$WORK/Shanhai.zip"
curl -fsSL "$BASE/Shanhai.sha256" -o "$WORK/sums"
(cd "$WORK" && grep " Shanhai.zip\$" sums | shasum -a 256 -c - >/dev/null) \
    || { echo "错误：校验和不符" >&2; exit 1; }

ditto -x -k "$WORK/Shanhai.zip" "$WORK/unzipped"
APP="$WORK/unzipped/山海.app"
codesign --verify --deep --strict "$APP" 2>/dev/null || { echo "错误：代码签名无效" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
    || { echo "错误：Bundle ID 不符" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || { echo "错误：签名者不符" >&2; exit 1; }

pkill -x Shanhai 2>/dev/null && sleep 1 || true
rm -rf "$DEST/山海.app"
ditto "$APP" "$DEST/山海.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/山海.app/Contents/Info.plist")
echo "==> 已安装山海 $VERSION 到 $DEST"
[ -n "${SHANHAI_NO_OPEN:-}" ] || open "$DEST/山海.app"
