#!/bin/bash
# ==============================================================================
# 自己署名SSL証明書生成スクリプト
# ==============================================================================
#
# 概要:
#   開発・テスト用の自己署名SSL証明書を生成します。
#   本番環境では社内PKI発行の証明書に置換してください。
#
# 使用方法:
#   bash scripts/generate-self-signed-cert.sh [ドメイン名]
#
# 例:
#   bash scripts/generate-self-signed-cert.sh librechat.internal.domain
#
# ==============================================================================

set -euo pipefail

# 共通ライブラリの読み込み
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

check_cmd openssl

FORCE_OVERWRITE=false
POSITIONAL_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE_OVERWRITE=true
            shift
            ;;
        -h|--help)
            echo "使用方法: bash scripts/generate-self-signed-cert.sh [-f|--force] [ドメイン名]"
            exit 0
            ;;
        *)
            POSITIONAL_DOMAIN="$1"
            shift
            ;;
    esac
done

# ドメイン名（引数または.envから取得）
CERT_DOMAIN="${POSITIONAL_DOMAIN:-${DOMAIN:-librechat.internal.domain}}"
CERT_DIR="${PROJECT_DIR}/nginx/certs"
CERT_DAYS=365

echo "=============================================="
echo "自己署名SSL証明書生成"
echo "=============================================="
echo "ドメイン:   ${CERT_DOMAIN}"
echo "出力先:     ${CERT_DIR}"
echo "有効期間:   ${CERT_DAYS}日"
echo ""

# 出力ディレクトリ作成
mkdir -p "${CERT_DIR}"

# 既存の証明書の確認
if [ -f "${CERT_DIR}/server.crt" ] && [ "${FORCE_OVERWRITE}" = false ]; then
    if [ -t 0 ]; then
        echo "警告: 既存の証明書が検出されました。上書きしますか？ (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "処理を中止しました。"
            exit 0
        fi
    else
        echo "警告: 既存の証明書が存在します。非対話実行のため上書きせずにスキップします。（上書きするには --force フラグを指定してください）"
        exit 0
    fi
fi

# OpenSSL設定の生成（SAN対応）
OPENSSL_CNF=$(mktemp)
cat > "${OPENSSL_CNF}" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
C = JP
ST = Tokyo
L = Tokyo
O = Enterprise Internal
OU = IT Security
CN = ${CERT_DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${CERT_DOMAIN}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# 証明書生成
echo "--- 秘密鍵と証明書を生成中 ---"
openssl req -x509 -nodes -newkey rsa:4096 \
    -keyout "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.crt" \
    -days "${CERT_DAYS}" \
    -config "${OPENSSL_CNF}"

# パーミッション設定（セキュリティ要件）
chmod 644 "${CERT_DIR}/server.crt"
chmod 600 "${CERT_DIR}/server.key"

# 一時ファイル削除
rm -f "${OPENSSL_CNF}"

# 証明書情報の表示
echo ""
echo "--- 生成された証明書情報 ---"
openssl x509 -in "${CERT_DIR}/server.crt" -noout -subject -dates -fingerprint

echo ""
echo "=============================================="
echo "証明書生成完了"
echo "=============================================="
echo ""
echo "生成ファイル:"
echo "  証明書:   ${CERT_DIR}/server.crt"
echo "  秘密鍵:   ${CERT_DIR}/server.key"
echo ""
echo "注意: この証明書は自己署名のため、ブラウザで警告が表示されます。"
echo "      本番環境では社内PKI発行の証明書に置換してください。"
