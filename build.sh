#!/bin/bash
# 构建 NiceWatch.app —— 不需要打开 Xcode 工程
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="NiceWatch.app"
BUNDLE_ID="com.emoxw.nicewatch"

echo "==> 1/4 编译（${CONFIG}）"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/NiceWatch"
if [ ! -f "$BIN_PATH" ]; then
  echo "编译产物不存在：$BIN_PATH"; exit 1
fi

echo "==> 2/4 组装 .app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/NiceWatch"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NiceWatch</string>
    <key>CFBundleDisplayName</key><string>NiceWatch</string>
    <key>CFBundleExecutable</key><string>NiceWatch</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>NiceWatch</string>
</dict>
</plist>
PLIST

echo "==> 3/4 签名（ad-hoc，本机自用）"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> 4/4 完成"
echo "产物：$(pwd)/$APP"
echo "启动：open \"$(pwd)/$APP\""
