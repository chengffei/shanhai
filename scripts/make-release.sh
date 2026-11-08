#!/bin/sh
# 构建 Release（仅 Apple 芯片），用 Apple Development 证书重签，产出 dist/ 里的 dmg、zip、sha256。
# 另出固定名 Shanhai.zip、Shanhai.sha256，install.sh 走 releases/latest/download/ 取，不碰有频率限制的 API。
set -e
cd "$(dirname "$0")/.."
for k in political physical vintage blackgold; do
  [ -f "Shanhai/Resources/Geo/$k.ktx" ] || { echo "缺少 $k.ktx，先跑 scripts/build_imagery.py" >&2; exit 1; }
done

xcodegen generate -q
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Shanhai.xcodeproj -scheme Shanhai -configuration Release \
  -derivedDataPath .build/DD ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build -quiet

STAGE=.build/release
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
APP="$STAGE/山海.app"
ditto .build/DD/Build/Products/Release/Shanhai.app "$APP"
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
codesign --force --options runtime --entitlements Shanhai/Shanhai.entitlements --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/Shanhai-$VERSION.dmg"
ZIP="dist/Shanhai-$VERSION.zip"
rm -f "$DMG" "$ZIP"
mkdir -p "$STAGE/dmg" && ditto "$APP" "$STAGE/dmg/山海.app" && ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "山海 $VERSION" -srcfolder "$STAGE/dmg" -format ULFO -quiet "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cp "$ZIP" dist/Shanhai.zip
(cd dist && shasum -a 256 "Shanhai-$VERSION.dmg" "Shanhai-$VERSION.zip" Shanhai.zip | tee "Shanhai-$VERSION.sha256" > Shanhai.sha256)
echo "签名：${IDENTITY:-ad-hoc}"
ls -lh dist/*"$VERSION"*
