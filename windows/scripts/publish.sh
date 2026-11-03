#!/bin/zsh
# 在 Mac 或 Linux 上交叉编译 Windows 版，生成 dist/ModelBar-win-<架构>.zip。
set -euo pipefail
cd "${0:A:h}/.."
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

for runtime in win-x64 win-arm64; do
  out="dist/ModelBar-$runtime"
  rm -rf "${out:?}" "${out:?}.zip"
  dotnet publish src/ModelBar.Gateway -c Release -r "$runtime" -o "$out" -v q
  dotnet publish src/ModelBar.App -c Release -r "$runtime" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
    -o "$out" -v q
  rm -f "${out:?}"/*.pdb
  (cd "$out" && zip -q -9 -r "../ModelBar-$runtime.zip" .)
  echo "已生成 $PWD/$out.zip"
done
