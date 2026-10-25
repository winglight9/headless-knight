#!/bin/bash
# 生成 DMG：app + 应用程序软链接 + 首次打开说明。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Knight.app"
DMG="$ROOT/build/Knight.dmg"
STAGING="$ROOT/build/dmg-staging"

if [ ! -d "$APP" ]; then
    echo "找不到 $APP，先跑 scripts/build-app.sh" >&2
    exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 说明只有一个真源：Resources/首次打开说明.txt。以前这段文本硬编码在脚本里，
# 结果一直停留在 1.1，没人记得改——现在打包顺手把它同步给官网下载页。
cp "$ROOT/Resources/首次打开说明.txt" "$STAGING/首次打开说明.txt"
mkdir -p "$ROOT/../site/download"
cp "$ROOT/Resources/首次打开说明.txt" "$ROOT/../site/download/首次打开说明.txt" 2>/dev/null || true

hdiutil create \
    -volname "无头骑士大师" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

echo "已生成 $DMG"
hdiutil imageinfo "$DMG" | grep -E "Format|Total Bytes" || true
