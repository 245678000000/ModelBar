#!/bin/zsh
# 在登录钥匙串里创建固定的签名证书，只需运行一次。
# 应用内更新靠这张证书确认新版的来源，临时签名每次编译都会变，没法用来确认。
# 私钥导入后不可导出，换电脑要重新创建，届时已安装的版本要手动更新一次。
set -euo pipefail

NAME="ModelBar Local Signing"
if security find-identity -p codesigning | grep -Fq "\"$NAME\""; then
  echo "证书已存在：$NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CONF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout "pass:$PASSWORD"
security import "$WORK/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -x -T /usr/bin/codesign >/dev/null
echo "已创建证书：$NAME"
