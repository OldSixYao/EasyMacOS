#!/bin/bash
set -euo pipefail
umask 077

signing_directory="$HOME/Library/Application Support/EasyMacOS/Signing"
identity_file="$signing_directory/identity.sha1"
certificate_name='EasyMacOS Local Development'
keychain_path="$(security default-keychain -d user | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"

if [ -f "$identity_file" ]; then
    identity="$(cat "$identity_file")"
    if [[ "$identity" =~ ^[0-9A-Fa-f]{40}$ ]] && security find-identity -v -p codesigning "$keychain_path" | grep -Fqi "$identity"; then
        echo "已配置固定的本地签名身份：$identity"
        exit 0
    fi
    echo '已保存的签名身份不可用。请在钥匙串中恢复原证书和私钥，避免更换身份导致重新授权。' >&2
    exit 1
fi

# 发现同名证书时不创建替代品，防止意外更换长期签名身份。
if security find-certificate -c "$certificate_name" "$keychain_path" >/dev/null 2>&1; then
    echo '钥匙串已有同名证书，请先检查并恢复本机签名配置，不能自动生成替代证书。' >&2
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/easymacos-signing.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
cat > "$temporary_directory/certificate.cnf" <<'EOF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = EasyMacOS Local Development
O = EasyMacOS Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -config "$temporary_directory/certificate.cnf" \
    -keyout "$temporary_directory/private.key" -out "$temporary_directory/certificate.pem" 2>/dev/null
openssl rand -hex 24 > "$temporary_directory/import-password"
openssl pkcs12 -export -name "$certificate_name" -passout "file:$temporary_directory/import-password" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$temporary_directory/private.key" -in "$temporary_directory/certificate.pem" \
    -out "$temporary_directory/identity.p12"
# 私钥仅允许系统签名工具访问，不使用允许任意应用访问的 -A。
security import "$temporary_directory/identity.p12" -k "$keychain_path" \
    -P "$(cat "$temporary_directory/import-password")" -T /usr/bin/codesign -x
# 只在当前用户域为代码签名信任此证书，不修改系统钥匙串或网站证书策略。
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$temporary_directory/certificate.pem"
identity="$(openssl x509 -in "$temporary_directory/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
if ! security find-identity -v -p codesigning "$keychain_path" | grep -Fqi "$identity"; then
    echo '证书已导入，但系统尚未将其识别为可用的代码签名身份。请检查钥匙串状态。' >&2
    exit 1
fi
mkdir -p "$signing_directory"
printf '%s\n' "$identity" > "$identity_file"
echo "已创建并保存固定的本地签名身份：$identity"
echo '私钥保存在登录钥匙串；临时私钥和导入文件会立即清理。首次切换签名后需要重新授权一次。'
