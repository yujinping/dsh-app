#!/usr/bin/env bash
set -euo pipefail

NAME="dsh-app"
SOURCE="dsh-app.swift"
DEST_APP="$(dirname "$0")/$NAME.app"

echo "▸ 生成图标…"
swift "$(dirname "$0")/gen-icon.swift"
iconutil -c icns /tmp/dsh-icon.iconset -o "/tmp/$NAME.icns"
echo "  ✅ .icns 生成完成 ($(ls -lh "/tmp/$NAME.icns" | awk '{print $5}'))"

echo "▸ 编译 Swift 源码…"
swiftc -O -o "/tmp/$NAME" "$SOURCE"

echo "▸ 创建 .app  bundle…"
rm -rf "$DEST_APP"
mkdir -p "$DEST_APP/Contents/MacOS"
mkdir -p "$DEST_APP/Contents/Resources"

cp "/tmp/$NAME" "$DEST_APP/Contents/MacOS/$NAME"
cp "/tmp/$NAME.icns" "$DEST_APP/Contents/Resources/$NAME.icns"

# Info.plist
cat > "$DEST_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.deepseek.harness-launcher</string>
    <key>CFBundleName</key>
    <string>DeepSeek Harness</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>$NAME</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "▸ 清理临时文件…"
rm -f "/tmp/$NAME" "/tmp/$NAME.icns"
rm -rf /tmp/dsh-icon.iconset

echo ""
echo "✅ 完成！App 已生成："
echo "   $DEST_APP"
echo ""
echo "双击运行即可。关闭窗口 = 终止 dsh。"
