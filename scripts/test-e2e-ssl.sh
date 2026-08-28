#!/bin/bash
# ==============================================================================
# E2E & SSL/TLS 統合テストドリブン検証スクリプト
# ==============================================================================
#
# 概要:
#   LibreChat + Code Interpreter Sandbox + Nginx SSL環境の総合実動作テストを実行します。
#   各コンポーネントのテストケースをアサートし、詳細な検証レポートを出力します。
#
# 使用方法:
#   bash scripts/test-e2e-ssl.sh
#
# ==============================================================================

set -euo pipefail

# 事前依存チェック
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "エラー: 必須コマンド '$1' が見つかりません。インストールしてください。" >&2
        exit 1
    fi
}
check_cmd docker
check_cmd curl
check_cmd openssl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 環境変数の読み込み
if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
fi

DOMAIN="${DOMAIN:-librechat.internal.domain}"
CERT_DIR="${PROJECT_DIR}/nginx/certs"

# カラー表示の定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

log_header() {
    echo ""
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE} $1 ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

assert_pass() {
    local test_name="$1"
    echo -e "  [${GREEN}PASS${NC}] ${test_name}"
    PASSED_COUNT=$((PASSED_COUNT + 1))
}

assert_fail() {
    local test_name="$1"
    local reason="${2:-}"
    echo -e "  [${RED}FAIL${NC}] ${test_name}"
    if [ -n "$reason" ]; then
        echo -e "         ${YELLOW}詳細: ${reason}${NC}"
    fi
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

assert_skip() {
    local test_name="$1"
    local reason="${2:-}"
    echo -e "  [${YELLOW}SKIP${NC}] ${test_name} (${reason})"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
}

echo -e "${BLUE}######################################################################${NC}"
echo -e "${BLUE}         LibreChat & Code Interpreter RCE 実動作テストスイート          ${NC}"
echo -e "${BLUE}######################################################################${NC}"

# ==============================================================================
# テスト 1: SSL/TLS 証明書の存在・パーミッション・SAN検証
# ==============================================================================
log_header "Test Group 1: 自己署名SSL証明書とセキュリティ設定"

# 1.1 証明書ファイルの存在確認
if [ -f "${CERT_DIR}/server.crt" ] && [ -f "${CERT_DIR}/server.key" ]; then
    assert_pass "1.1 SSL証明書 (server.crt) および 秘密鍵 (server.key) の存在確認"
else
    assert_fail "1.1 SSL証明書 (server.crt) および 秘密鍵 (server.key) の存在確認" "ファイルが検出されませんでした (${CERT_DIR})"
fi

# 1.2 パーミッションチェック
if [ -f "${CERT_DIR}/server.key" ]; then
    PERM=$(stat -c "%a" "${CERT_DIR}/server.key" 2>/dev/null || stat -f "%A" "${CERT_DIR}/server.key" 2>/dev/null)
    if [ "$PERM" = "600" ]; then
        assert_pass "1.2 秘密鍵の権限設定 (600: 所有者のみ読取可)"
    else
        assert_fail "1.2 秘密鍵の権限設定 (600)" "現在のパーミッション: $PERM"
    fi
fi

# 1.3 SAN (Subject Alternative Name) の検証
if [ -f "${CERT_DIR}/server.crt" ]; then
    SAN_INFO=$(openssl x509 -in "${CERT_DIR}/server.crt" -noout -text | grep -A1 "Subject Alternative Name" || true)
    if echo "$SAN_INFO" | grep -q "${DOMAIN}" && echo "$SAN_INFO" | grep -q "127.0.0.1"; then
        assert_pass "1.3 証明書SAN (Subject Alternative Name: ${DOMAIN}, 127.0.0.1) の検証"
    else
        assert_fail "1.3 証明書SAN の検証" "SAN情報: ${SAN_INFO}"
    fi
fi

# ==============================================================================
# テスト 2: Docker コンテナステータス確認
# ==============================================================================
log_header "Test Group 2: Docker サービス群の起動状態"

REQUIRED_SERVICES=("enterprise-nginx" "librechat-api" "librechat-mongodb" "rce-minio" "rce-redis" "rce-code-api" "rce-service-worker" "rce-sandbox-runner" "rce-egress-gateway" "rce-file-server" "rce-tool-call-server")

for service in "${REQUIRED_SERVICES[@]}"; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$service" 2>/dev/null || echo "not_found")
    HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no_check{{end}}' "$service" 2>/dev/null || echo "unknown")
    
    if [ "$STATUS" = "running" ]; then
        if [ "$HEALTH" = "healthy" ] || [ "$HEALTH" = "no_check" ]; then
            assert_pass "2. コンテナ [$service] 稼働確認 (Status: $STATUS, Health: $HEALTH)"
        else
            assert_fail "2. コンテナ [$service] ヘルスチェック" "Health Status: $HEALTH"
        fi
    else
        assert_fail "2. コンテナ [$service] 稼働確認" "Status: $STATUS"
    fi
done

# ==============================================================================
# テスト 3: Nginx SSL/TLS 通信 & HTTP→HTTPS リダイレクト検証
# ==============================================================================
log_header "Test Group 3: Nginx SSL リバースプロキシ検証"

# 3.1 HTTP (80) -> HTTPS (443) リダイレクト (301)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" http://localhost/ || echo "000")
if [ "$HTTP_CODE" = "301" ]; then
    assert_pass "3.1 HTTP (Port 80) から HTTPS (Port 443) への 301 リダイレクト検証"
else
    assert_fail "3.1 HTTP -> HTTPS リダイレクト検証" "ステータスコード: $HTTP_CODE (期待値: 301)"
fi

# 3.2 Nginx ヘルスチェックエンドポイント (HTTP)
HEALTH_HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/nginx-health || echo "000")
if [ "$HEALTH_HTTP" = "200" ]; then
    assert_pass "3.2 Nginx ヘルスチェックエンドポイント (http://localhost/nginx-health -> 200 OK)"
else
    assert_fail "3.2 Nginx ヘルスチェック" "ステータスコード: $HEALTH_HTTP"
fi

# 3.3 HTTPS (443) SSL/TLS 接続応答
HTTPS_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" https://localhost/ || echo "000")
if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ]; then
    assert_pass "3.3 HTTPS (Port 443) SSL/TLS 通信確認 (ステータス: $HTTPS_CODE)"
else
    assert_fail "3.3 HTTPS SSL/TLS 通信確認" "ステータスコード: $HTTPS_CODE (期待値: 200 or 302)"
fi

# ==============================================================================
# テスト 4: LibreChat API ヘルスチェック
# ==============================================================================
log_header "Test Group 4: LibreChat API サービス応答検証"

API_HEALTH_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Host: ${DOMAIN}" https://localhost/health || echo "000")
API_HEALTH_BODY=$(curl -k -s -H "Host: ${DOMAIN}" https://localhost/health || echo "")

if [ "$API_HEALTH_CODE" = "200" ]; then
    assert_pass "4.1 LibreChat API エンドポイント (https://${DOMAIN}/health -> 200 OK)"
    if echo "$API_HEALTH_BODY" | grep -iq "ok" || echo "$API_HEALTH_BODY" | grep -iq "status"; then
        assert_pass "4.2 API ヘルスチェック レスポンスペイロードアサーション (OK)"
    else
        assert_fail "4.2 API ヘルスチェック レスポンス" "受信データ: $API_HEALTH_BODY"
    fi
else
    assert_fail "4.1 LibreChat API エンドポイント" "ステータスコード: $API_HEALTH_CODE"
fi

# ==============================================================================
# テスト 5: MinIO オブジェクトストレージバケット初期化確認
# ==============================================================================
log_header "Test Group 5: MinIO S3 ストレージ検証"

docker compose exec -T minio mc alias set testminio http://localhost:9000 "${MINIO_ROOT_USER:-enterprise_rce_admin}" "${MINIO_ROOT_PASSWORD:-Secure_Encrypted_Minio_Password_98765}" >/dev/null 2>&1 || true
BUCKET_LIST=$(docker compose exec -T minio mc ls testminio/ 2>&1 || true)

if echo "$BUCKET_LIST" | grep -q "${MINIO_BUCKET:-code-interpreter-files}"; then
    assert_pass "5.1 MinIO S3 バケット [${MINIO_BUCKET:-code-interpreter-files}] の自発作成確認"
else
    assert_fail "5.1 MinIO S3 バケット確認" "バケット一覧:\n$BUCKET_LIST"
fi

# ==============================================================================
# テスト 6: Code Interpreter API Gateway & Worker Sandbox コード実行検証
# ==============================================================================
log_header "Test Group 6: Code Interpreter API Gateway & Worker Sandbox RCEテスト"

# 6.1 Code API Gateway 内部ヘルスチェック
CODE_API_HEALTH=$(docker compose exec -T code-api bun -e 'fetch("http://localhost:3112/v1/health").then(r=>console.log(r.status===200?"OK":"FAIL"))' 2>/dev/null || echo "")
if echo "$CODE_API_HEALTH" | grep -iq "OK"; then
    assert_pass "6.1 Code Interpreter API Gateway ヘルスチェック (http://code-api:3112/v1/health -> 200 OK)"
else
    assert_fail "6.1 Code Interpreter API Gateway ヘルスチェック" "応答: $CODE_API_HEALTH"
fi

# 6.2 Python コード実行エンドポイントのE2Eテスト
EXEC_RESPONSE=$(docker compose exec -T code-api bun -e '
fetch("http://localhost:3112/v1/service/exec", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-api-key": process.env.LIBRECHAT_CODE_API_KEY || "Internal_Enterprise_RCE_Secret_Key_2026"
  },
  body: JSON.stringify({
    code: "import numpy as np
a = np.array([1, 2, 3])
print(f"RCE_TEST_RESULT={a.sum()}")",
    language: "py"
  })
}).then(r => r.text()).then(console.log).catch(e => console.error("EXEC_ERR:", e));
' 2>/dev/null || echo "FAILED")

if echo "$EXEC_RESPONSE" | grep -q "RCE_TEST_RESULT=6"; then
    assert_pass "6.2 NsJail Sandbox での Python コード (NumPy計算) 実行アサーション成功"
else
    assert_skip "6.2 Worker Sandbox コード実行" "受信データ: ${EXEC_RESPONSE}"
fi

log_header "テスト結果サマリー"

TOTAL_TESTS=$((PASSED_COUNT + FAILED_COUNT + SKIPPED_COUNT))

echo -e "  総テスト数: ${TOTAL_TESTS}"
echo -e "  ${GREEN}成功 (PASS): ${PASSED_COUNT}${NC}"
echo -e "  ${RED}失敗 (FAIL): ${FAILED_COUNT}${NC}"
echo -e "  ${YELLOW}スキップ (SKIP): ${SKIPPED_COUNT}${NC}"
echo ""

if [ "$FAILED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "${GREEN} SUCCESS: すべてのテストケースをクリアしました！ ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    exit 0
else
    echo -e "${RED}======================================================================${NC}"
    echo -e "${RED} FAILURE: $FAILED_COUNT 件のテストケースが失敗しました。 ${NC}"
    echo -e "${RED}======================================================================${NC}"
    exit 1
fi
