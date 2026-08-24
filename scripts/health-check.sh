#!/bin/bash
# ==============================================================================
# 全サービスヘルスチェック & セキュリティ検証スクリプト
# ==============================================================================
#
# 概要:
#   デプロイ後の全サービスの健全性とセキュリティ要件の検証を実施します。
#   参照計画書セクション6のセキュリティ検証・監査プロトコルに準拠。
#
# 使用方法:
#   bash scripts/health-check.sh
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    source "$PROJECT_DIR/.env"
fi

# カラー出力定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# テスト結果表示関数
pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
}

echo "=============================================="
echo "LibreChat & Code Interpreter ヘルスチェック"
echo "=============================================="
echo "実行日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ==========================================================================
# テスト1: コンテナ起動状態の確認
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "テスト1: コンテナ起動状態の確認"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXPECTED_CONTAINERS=(
    "enterprise-nginx"
    "librechat-api"
    "librechat-mongodb"
    "rce-minio"
    "rce-redis"
    "rce-code-api"
    "rce-code-worker"
)

for container in "${EXPECTED_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        STATUS=$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null)
        if [ "$STATUS" = "running" ]; then
            pass "${container}: 稼働中"
        else
            fail "${container}: 状態異常 (${STATUS})"
        fi
    else
        fail "${container}: コンテナが見つかりません"
    fi
done

echo ""

# ==========================================================================
# テスト2: サービスヘルスチェック
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "テスト2: サービスヘルスチェック"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# MongoDB接続確認
if docker exec librechat-mongodb mongosh --eval "db.adminCommand('ping')" --quiet 2>/dev/null | grep -q "ok"; then
    pass "MongoDB: 接続正常"
else
    fail "MongoDB: 接続失敗"
fi

# Redis接続確認
REDIS_PASS="${REDIS_PASSWORD:-Secure_Redis_Password_54321}"
if docker exec rce-redis redis-cli -a "${REDIS_PASS}" ping 2>/dev/null | grep -q "PONG"; then
    pass "Redis: 接続正常 (PONG応答)"
else
    fail "Redis: 接続失敗"
fi

# MinIO接続確認
if docker exec rce-minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER:-enterprise_rce_admin}" "${MINIO_ROOT_PASSWORD:-Secure_Encrypted_Minio_Password_98765}" 2>/dev/null; then
    pass "MinIO: 接続正常"

    # バケット存在確認
    BUCKET="${MINIO_BUCKET:-code-interpreter-files}"
    if docker exec rce-minio mc ls "local/${BUCKET}" 2>/dev/null; then
        pass "MinIO: バケット '${BUCKET}' 存在確認"
    else
        warn "MinIO: バケット '${BUCKET}' が見つかりません（minio-initが未実行の可能性）"
    fi
else
    fail "MinIO: 接続失敗"
fi

echo ""

# ==========================================================================
# テスト3: ネットワーク分離の検証
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "テスト3: ネットワーク分離の検証"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# rce-isolated ネットワークの内部フラグ確認
ISOLATED_INTERNAL=$(docker network inspect rce_lc_rce-isolated --format '{{.Internal}}' 2>/dev/null || echo "error")
if [ "$ISOLATED_INTERNAL" = "true" ]; then
    pass "rce-isolated ネットワーク: internal=true（外部通信遮断）"
else
    fail "rce-isolated ネットワーク: internal=true が設定されていません（${ISOLATED_INTERNAL}）"
fi

# Worker Sandbox からの外部通信遮断テスト（SSRF防御）
info "Worker Sandbox からの外部通信テスト（SSRF防御）..."
if docker exec rce-code-worker timeout 5 ping -c 1 8.8.8.8 2>/dev/null; then
    fail "SSRF防御: Worker Sandbox から外部ネットワークへの通信が可能です（危険）"
else
    pass "SSRF防御: Worker Sandbox から外部ネットワークへの通信が遮断されています"
fi

# Worker Sandbox からホストネットワークへのアクセス遮断テスト
if docker exec rce-code-worker timeout 5 wget -q -O /dev/null http://host.docker.internal 2>/dev/null; then
    warn "ネットワーク隔離: Worker Sandbox からホストネットワークへのアクセスが可能です"
else
    pass "ネットワーク隔離: Worker Sandbox からホストネットワークへのアクセスが遮断されています"
fi

echo ""

# ==========================================================================
# テスト4: SSL/TLS終端の確認
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "テスト4: SSL/TLS終端の確認"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# HTTP→HTTPSリダイレクト確認
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
if [ "$HTTP_STATUS" = "301" ]; then
    pass "HTTPリダイレクト: HTTP→HTTPS (301) が正常動作"
else
    warn "HTTPリダイレクト: 期待: 301, 実際: ${HTTP_STATUS}"
fi

# HTTPS接続確認
HTTPS_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/ 2>/dev/null || echo "000")
if [ "$HTTPS_STATUS" = "200" ] || [ "$HTTPS_STATUS" = "302" ]; then
    pass "HTTPS接続: 正常応答 (HTTP ${HTTPS_STATUS})"
else
    warn "HTTPS接続: 期待: 200/302, 実際: ${HTTPS_STATUS}"
fi

# SSL証明書情報の表示
info "SSL証明書情報:"
if [ -f "${PROJECT_DIR}/nginx/certs/server.crt" ]; then
    CERT_SUBJECT=$(openssl x509 -in "${PROJECT_DIR}/nginx/certs/server.crt" -noout -subject 2>/dev/null)
    CERT_EXPIRE=$(openssl x509 -in "${PROJECT_DIR}/nginx/certs/server.crt" -noout -enddate 2>/dev/null)
    info "  Subject: ${CERT_SUBJECT}"
    info "  Expire:  ${CERT_EXPIRE}"
    pass "SSL証明書: ファイル存在確認"
else
    fail "SSL証明書: nginx/certs/server.crt が見つかりません"
fi

echo ""

# ==========================================================================
# テスト5: リソース制限の確認
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "テスト5: リソース制限の確認"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Worker Sandbox のリソース制限確認
WORKER_MEM=$(docker inspect rce-code-worker --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
if [ "$WORKER_MEM" != "0" ] && [ -n "$WORKER_MEM" ]; then
    WORKER_MEM_MB=$((WORKER_MEM / 1024 / 1024))
    pass "Worker メモリ制限: ${WORKER_MEM_MB}MB"
else
    warn "Worker メモリ制限: 未設定"
fi

WORKER_PIDS=$(docker inspect rce-code-worker --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo "0")
if [ "$WORKER_PIDS" != "0" ] && [ "$WORKER_PIDS" != "-1" ] && [ -n "$WORKER_PIDS" ]; then
    pass "Worker PID制限: ${WORKER_PIDS}"
else
    warn "Worker PID制限: 未設定（Fork Bomb攻撃に脆弱）"
fi

# Worker Sandbox の privileged モード確認
WORKER_PRIVILEGED=$(docker inspect rce-code-worker --format '{{.HostConfig.Privileged}}' 2>/dev/null || echo "unknown")
if [ "$WORKER_PRIVILEGED" = "true" ]; then
    warn "Worker privileged モード: 有効（NsJailに必要だが、セキュリティリスクあり）"
else
    info "Worker privileged モード: 無効"
fi

echo ""

# ==========================================================================
# 結果サマリー
# ==========================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "検証結果サマリー"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "  ${GREEN}PASS${NC}: ${PASS_COUNT}"
echo -e "  ${YELLOW}WARN${NC}: ${WARN_COUNT}"
echo -e "  ${RED}FAIL${NC}: ${FAIL_COUNT}"
echo ""

TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}全テスト合格 (${PASS_COUNT}/${TOTAL})${NC}"
    exit 0
else
    echo -e "${RED}テスト失敗あり (${FAIL_COUNT}件の失敗)${NC}"
    exit 1
fi
