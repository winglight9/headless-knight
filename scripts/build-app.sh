#!/bin/bash
# 编译 release 版，手工组装 .app（没有 Xcode，只能自己拼），ad-hoc 签名。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Knight.app"
cd "$ROOT"

echo "==> swift build -c release"
"$ROOT/scripts/swift.sh" build -c release
BIN="$("$ROOT/scripts/swift.sh" build -c release --show-bin-path)"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Knight" "$APP/Contents/MacOS/Knight"
cp "$BIN/hkm-helper" "$APP/Contents/Resources/com.headlessknight.helper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Knight" "$APP/Contents/Resources/com.headlessknight.helper"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> 生成图标"
    "$ROOT/scripts/make-icon.sh" || echo "   图标生成失败，跳过（不影响启动）"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完成：$APP"
echo "    启动：open \"$APP\""
