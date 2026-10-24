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

cat > "$STAGING/首次打开说明.txt" <<'NOTE'
无头骑士大师 1.1

安装
  把「无头骑士大师」拖进「应用程序」文件夹。

第一次打开
  这个应用没有 Apple 开发者签名，macOS 会拦住它。
  在「应用程序」里右键点图标 → 打开 → 再点一次「打开」。
  之后就可以正常双击了。

使用
  菜单栏出现公文包图标即表示已经在运行。
  出门前点图标 → 开始外出模式 → 拔掉显示器。
  回来插上显示器，点图标看这次有没有被唤醒。
NOTE

hdiutil create \
    -volname "无头骑士大师" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

echo "已生成 $DMG"
hdiutil imageinfo "$DMG" | grep -E "Format|Total Bytes" || true
