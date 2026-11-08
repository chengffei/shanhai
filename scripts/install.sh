#!/bin/sh
# 构建 Release 并装到 /Applications。
set -e
cd "$(dirname "$0")/.."

if pgrep -x Shanhai >/dev/null; then
  echo "山海正在运行，先退出再装" >&2
  exit 1
fi
[ -f Shanhai/Resources/Geo/physical.ktx ] || { echo "缺少底图，先跑 scripts/build_imagery.py" >&2; exit 1; }

xcodegen generate -q
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Shanhai.xcodeproj -scheme Shanhai -configuration Release \
  -derivedDataPath .build/DD build -quiet

LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PRODUCTS=.build/DD/Build/Products
DEST="/Applications/山海.app"
rm -rf "$DEST"
cp -R "$PRODUCTS/Release/Shanhai.app" "$DEST"
for config in Debug Release; do
  "$LS" -u "$PRODUCTS/$config/Shanhai.app" 2>/dev/null || true
done
touch "$DEST" "$DEST/Contents/Info.plist"
"$LS" -f "$DEST"
echo "已安装 $DEST"
