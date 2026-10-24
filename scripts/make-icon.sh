#!/bin/bash
# 生成 AppIcon.icns：用 swift 画 1024 PNG，再用 iconutil 打包。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macosx13.0"

# 直接调 swiftc 时必须自己带上 -sdk / -target：SwiftPM 会替我们传这两个参数，
# 裸调用不会，缺了就会去加载另一份坏的 module.modulemap（SwiftBridging 重复定义）。
if [ -x "$ROOT/.build-toolchain/swiftc" ]; then
    # 打过 VFS overlay 的 swiftc，否则 AppKit 模块建不起来
    "$ROOT/.build-toolchain/swiftc" -sdk "$SDK" -target "$TARGET" \
        "$ROOT/Resources/make-icon.swift" -o "$WORK/make-icon"
else
    swiftc -sdk "$SDK" -target "$TARGET" \
        "$ROOT/Resources/make-icon.swift" -o "$WORK/make-icon"
fi
"$WORK/make-icon" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "已生成 $ROOT/Resources/AppIcon.icns"
