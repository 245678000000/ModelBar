#!/bin/zsh
# 把 dist/ModelBar.app 打包成带“应用程序”快捷方式的 DMG。
set -euo pipefail
cd "${0:A:h}/.."
[[ -d dist/ModelBar.app ]] || ./scripts/build-app.sh
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/ModelBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/ModelBar.dmg
hdiutil create -quiet -volname ModelBar -srcfolder "$STAGE" -ov -format UDZO dist/ModelBar.dmg
echo "已生成 $PWD/dist/ModelBar.dmg"
