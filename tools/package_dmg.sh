#!/bin/bash
# 构建可拖入 Applications 安装的通用版 DMG。
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh release universal
lipo -verify_arch arm64 x86_64 NiceWatch.app/Contents/MacOS/NiceWatch
codesign --verify --deep --strict NiceWatch.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' NiceWatch.app/Contents/Info.plist)
OUTPUT_DIR="$(pwd)/dist"
mkdir -p "$OUTPUT_DIR"
DMG="$OUTPUT_DIR/NiceWatch-${VERSION}-universal.dmg"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/nicewatch-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

ditto NiceWatch.app "$STAGING/NiceWatch.app"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/安装说明.txt" <<'NOTE'
NiceWatch

安装：将 NiceWatch.app 拖入 Applications 文件夹，然后从“应用程序”启动。
系统要求：macOS 13 或更高，支持 Apple Silicon 与 Intel。

此版本使用临时签名（ad-hoc），尚未经过 Apple 公证。
首次启动时 macOS 可能提示无法验证开发者，请确认下载来源。

项目与使用说明：https://github.com/EmoXW/NiceWatch
NOTE

hdiutil create -volname NiceWatch -srcfolder "$STAGING" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "安装包：$DMG"
