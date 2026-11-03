#!/bin/zsh
# 生成 Mac 版发布需要的文件：DMG、应用内更新用的 zip 和校验值。
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh

# 已安装的版本只接受这一张证书，同名的新证书也不行，用错了发布出去用户就更新不了。
RELEASE_CERT="ab49b631a17d391674c28ad5ae9d1f82f135ecc7"
REQUIREMENT="$(codesign -d -r- dist/ModelBar.app 2>&1)"
if [[ "$REQUIREMENT" != *"certificate leaf = H\"$RELEASE_CERT\""* ]]; then
  echo "错误：签名证书不是发布用的那张，已安装的版本不会接受这个包。" >&2
  echo "确实要换证书时，请修改这个脚本里的 RELEASE_CERT，并告知用户要手动安装一次。" >&2
  exit 1
fi

./scripts/package-dmg.sh
rm -f dist/ModelBar-mac.zip dist/SHA256SUMS.txt
ditto -c -k --keepParent dist/ModelBar.app dist/ModelBar-mac.zip
(cd dist && shasum -a 256 ModelBar.dmg ModelBar-mac.zip > SHA256SUMS.txt)

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/ModelBar.app/Contents/Info.plist)"
echo "已生成 dist/ModelBar.dmg、dist/ModelBar-mac.zip 和 dist/SHA256SUMS.txt"
echo "发布时标签用 mac-v$VERSION，并上传这三个文件。"
