#!/bin/zsh
# 生成 Mac 版发布需要的文件：DMG、应用内更新用的 zip 和校验值。
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh

# 应用内更新靠证书确认新版的来源，临时签名的版本发布出去就没法再自动更新了。
SIGNATURE="$(codesign -dvv dist/ModelBar.app 2>&1)"
if [[ "$SIGNATURE" != *$'\nAuthority=ModelBar Local Signing\n'* ]]; then
  echo "错误：没有用固定证书签名，请先运行 ./scripts/make-signing-cert.sh" >&2
  exit 1
fi

./scripts/package-dmg.sh
rm -f dist/ModelBar-mac.zip dist/SHA256SUMS.txt
ditto -c -k --keepParent dist/ModelBar.app dist/ModelBar-mac.zip
(cd dist && shasum -a 256 ModelBar.dmg ModelBar-mac.zip > SHA256SUMS.txt)

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/ModelBar.app/Contents/Info.plist)"
echo "已生成 dist/ModelBar.dmg、dist/ModelBar-mac.zip 和 dist/SHA256SUMS.txt"
echo "发布时标签用 mac-v$VERSION，并上传这三个文件。"
