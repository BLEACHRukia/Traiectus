#!/bin/bash
# ============================================================================
#  生成用于本地签名的自签名证书（身份名：Traiectus Dev Code Signing）
# ----------------------------------------------------------------------------
#  为什么需要：ad-hoc 签名（codesign -s -）每次重编都会变，导致 macOS 认为
#  "这是另一个 App"，于是「辅助功能」授权每次都要重新给。用一个固定的自签名
#  证书签名，签名就稳定，授权一次长期有效。
#
#  做三件事：
#    1) 用 openssl 生成带 "Code Signing" 用途的 RSA 证书（有效期 10 年）
#    2) 打包成 p12 导入登录钥匙串（允许 codesign 使用该私钥）
#    3) 把该证书标记为"代码签名受信任"（仅当前用户域）
#
#  用法：  ./make-signing-identity.sh
#          想换名字：TRAIECTUS_SIGN_NAME="别的名字" ./make-signing-identity.sh
#  注意：  runs interactively - macOS may ask you to authorize the trust change.
#  生成后把证书的 SHA-1 填进 build.sh 的 SIGN_HASH（避免同名证书歧义）。
#
#  ⚠️ 换新证书 = 换了一个"签名身份" → macOS 认为这是另一个 App →
#     「辅助功能」「自动化」授权都会失效，要重新给一次（老证书留着的话可以退回去）。
# ============================================================================

set -euo pipefail

NAME="${TRAIECTUS_SIGN_NAME:-Traiectus Dev Code Signing}"
WORK="$(mktemp -d /tmp/traiectus-cert.XXXXXX)"
KC="$HOME/Library/Keychains/login.keychain-db"
# p12 只是临时导一次，密码随便定（真正的私钥在登录钥匙串里）
P12PASS="traiectus-import"

cd "$WORK"
cat > openssl.cnf <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config openssl.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout pass:"$P12PASS"
security import id.p12 -k "$KC" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security -A
security add-trusted-cert -r trustRoot -p codeSign -k "$KC" cert.pem

echo ""
echo "可用签名身份："
security find-identity -v -p codesigning | sed -n '1,6p'
echo ""
echo "把上面那串 40 位 SHA-1 填进 build.sh 的 SIGN_HASH，然后用它签名。"
echo "（/tmp 下的私钥文件 ${WORK} 用完可以删掉；钥匙串里已有副本。）"
