#!/usr/bin/env bash
set -euo pipefail

NAME="dsh-app"
SOURCE="dsh-app.swift"
MIN_MACOS="12.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_APP="$SCRIPT_DIR/$NAME.app"

# 参数解析：版本号必传（如 0.1.0），--dmg / --no-app / --arch 可选
# --no-app 仅在与 --dmg 同时出现时生效：DMG 成功后删除 .app
# --arch 指定单一架构（x86_64 或 arm64）；不指定默认构建 Universal 二进制
usage() {
    cat <<EOF
用法: $0 <版本号> [选项]

必要参数:
  <版本号>            如 0.1.0，写入 Info.plist 并用于 DMG 命名

选项:
  --dmg               额外生成 DMG 到 dist/（内含 App 与 /Applications 链接）
  --no-app            仅在与 --dmg 同时出现时生效：DMG 成功后删除 .app
  --arch <架构>       只编译指定架构（x86_64 或 arm64）；不传则构建
                      Universal 二进制，DMG 命名为 -universal

示例:
  $0 0.1.0                        # 仅 .app（Universal）
  $0 0.1.0 --dmg                  # .app + Universal DMG
  $0 0.1.0 --arch arm64           # 仅 arm64 .app
  $0 0.1.0 --arch arm64 --dmg     # 仅 arm64 .app + DMG
  $0 0.1.0 --dmg --no-app         # 仅 Universal DMG（构建后删除 .app）
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

MAKE_DMG=false
NO_APP=false
VERSION=""
ARCH=""   # 为空 = Universal；x86_64 | arm64 = 单一架构
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) MAKE_DMG=true; shift ;;
        --no-app) NO_APP=true; shift ;;
        --arch)
            if [[ $# -lt 2 ]]; then
                echo "错误: --arch 需要一个参数（x86_64 或 arm64）" >&2
                usage
                exit 1
            fi
            case "$2" in
                x86_64|arm64) ARCH="$2" ;;
                *)
                    echo "错误: 无效的架构 ${2}（可选 x86_64 或 arm64）" >&2
                    usage
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                VERSION="$1"
                shift
            else
                echo "错误: 无效的版本号 ${1}（格式如 0.1.0）" >&2
                usage
                exit 1
            fi
            ;;
    esac
done
if [[ -z "$VERSION" ]]; then
    echo "错误: 缺少版本号" >&2
    usage
    exit 1
fi
if [[ "$NO_APP" == true && "$MAKE_DMG" != true ]]; then
    echo "错误: --no-app 必须与 --dmg 同时使用（否则没有产物）" >&2
    usage
    exit 1
fi

echo "▸ 使用 icon.icns…"
cp "$SCRIPT_DIR/icon.icns" "/tmp/$NAME.icns"
echo "  ✅ 复制完成 ($(ls -lh "/tmp/$NAME.icns" | awk '{print $5}'))"

if [[ -n "$ARCH" ]]; then
    echo "▸ 编译 Swift 源码（架构: ${ARCH}，最低 macOS ${MIN_MACOS}）…"
    swiftc -O -target "${ARCH}-apple-macosx${MIN_MACOS}" -o "/tmp/$NAME" "$SOURCE"
    echo "  ✅ ${ARCH} 二进制生成完成"
    DMG_ARCH="$ARCH"
else
    echo "▸ 编译 Swift 源码（Universal: x86_64 + arm64，最低 macOS ${MIN_MACOS}）…"
    swiftc -O -target "x86_64-apple-macosx${MIN_MACOS}" -o "/tmp/$NAME-x86_64" "$SOURCE"
    swiftc -O -target "arm64-apple-macosx${MIN_MACOS}" -o "/tmp/$NAME-arm64" "$SOURCE"
    lipo -create "/tmp/$NAME-x86_64" "/tmp/$NAME-arm64" -output "/tmp/$NAME"
    echo "  ✅ Universal 二进制生成完成: $(lipo -info "/tmp/$NAME" | sed 's/^[^:]*: //')"
    DMG_ARCH="universal"
fi

echo "▸ 创建 .app  bundle…"
rm -rf "$DEST_APP"
mkdir -p "$DEST_APP/Contents/MacOS"
mkdir -p "$DEST_APP/Contents/Resources"
mkdir -p "$DEST_APP/Contents/Resources/js"

cp "/tmp/$NAME" "$DEST_APP/Contents/MacOS/$NAME"
cp "/tmp/$NAME.icns" "$DEST_APP/Contents/Resources/$NAME.icns"
cp "$SCRIPT_DIR/js/polyfills.js" "$DEST_APP/Contents/Resources/js/polyfills.js"
cp "$SCRIPT_DIR/js/console-bridge.js" "$DEST_APP/Contents/Resources/js/console-bridge.js"

# Info.plist
cat > "$DEST_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.deepseek.dsh-app</string>
    <key>CFBundleName</key>
    <string>dsh-app</string>
    <key>CFBundleDisplayName</key>
    <string>dsh-app</string>
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
if [[ "$NO_APP" != true ]]; then
    echo "✅ 完成！App 已生成：$DEST_APP"
fi

# ─── DMG ────────────────────────────────────────────────────
if [[ "$MAKE_DMG" == true ]]; then
    echo "▸ 生成 DMG…"
    STAGE="/tmp/$NAME-dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$DEST_APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"

    mkdir -p "$SCRIPT_DIR/dist"   # DMG 统一输出到 dist/
    DMG_PATH="$SCRIPT_DIR/dist/$NAME-$VERSION-$DMG_ARCH.dmg"
    rm -f "$DMG_PATH"
    hdiutil create -volname "dsh-app" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGE"

    echo ""
    echo "✅ DMG 已生成：$DMG_PATH"

    if [[ "$NO_APP" == true ]]; then
        echo "▸ 按 --no-app 选项删除 .app…"
        rm -rf "$DEST_APP"
        echo "  ✅ 已删除：$DEST_APP"
    fi
fi

echo "双击运行即可。关闭窗口 = 终止 dsh。"
