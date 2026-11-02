#!/bin/zsh
# 只装了 Command Line Tools 时，需要手动指定 Swift Testing 的位置。
set -euo pipefail
cd "${0:A:h}/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ -d "$FW/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  swift test "$@"
fi
