#!/usr/bin/env bash
set -euo pipefail

NAME="dsh-app"
SOURCE="dsh-app.swift"
MIN_MACOS="12.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_APP="$SCRIPT_DIR/$NAME.app"

# 参数解析：版本号必传（如 0.1.0），--dmg 可选可乱序
MAKE_DMG=false
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=true ;;
        *)
            if [[ "$arg" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$arg"
            else
                echo "无效的版本号: ${arg}（格式如 0.1.0）" >&2
                echo "用法: $0 <版本号，如 0.1.0> [--dmg]" >&2
                exit 1
            fi
            ;;
    esac
done
if [[ -z "$VERSION" ]]; then
    echo "用法: $0 <版本号，如 0.1.0> [--dmg]" >&2
    exit 1
fi

echo "▸ 使用 icon.icns…"
cp "$SCRIPT_DIR/icon.icns" "/tmp/$NAME.icns"
echo "  ✅ 复制完成 ($(ls -lh "/tmp/$NAME.icns" | awk '{print $5}'))"

echo "▸ 编译 Swift 源码（Universal: x86_64 + arm64，最低 macOS ${MIN_MACOS}）…"
swiftc -O -target "x86_64-apple-macosx${MIN_MACOS}" -o "/tmp/$NAME-x86_64" "$SOURCE"
swiftc -O -target "arm64-apple-macosx${MIN_MACOS}" -o "/tmp/$NAME-arm64" "$SOURCE"
lipo -create "/tmp/$NAME-x86_64" "/tmp/$NAME-arm64" -output "/tmp/$NAME"
echo "  ✅ Universal 二进制生成完成: $(lipo -info "/tmp/$NAME" | sed 's/^[^:]*: //')"

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
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
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
rm -f "/tmp/$NAME" "/tmp/$NAME-x86_64" "/tmp/$NAME-arm64" "/tmp/$NAME.icns"

echo ""
echo "✅ 完成！App 已生成：$DEST_APP"

# ─── DMG ────────────────────────────────────────────────────
if [[ "$MAKE_DMG" == true ]]; then
    echo "▸ 生成 DMG…"
    STAGE="/tmp/$NAME-dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$DEST_APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"

    DMG_PATH="$SCRIPT_DIR/$NAME-$VERSION.dmg"
    rm -f "$DMG_PATH"
    hdiutil create -volname "DeepSeek Harness" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGE"

    echo ""
    echo "✅ DMG 已生成：$DMG_PATH"
fi

echo "双击运行即可。关闭窗口 = 终止 dsh。"