#!/bin/bash
# ==============================================================================
# MinIO バケット初期化スクリプト
# ==============================================================================
#
# 概要:
#   MinIO起動後に code-interpreter-files バケットを自動作成します。
#   docker-compose.yml の minio-init サービスでも同等の処理を行いますが、
#   手動実行が必要な場合にこのスクリプトを使用できます。
#
# 使用方法:
#   bash scripts/init-minio.sh
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

# 環境変数の読み込み
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
fi

MINIO_ROOT_USER="${MINIO_ROOT_USER:-enterprise_rce_admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-Secure_Encrypted_Minio_Password_98765}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-minio:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-code-interpreter-files}"

echo "=============================================="
echo "MinIO バケット初期化"
echo "=============================================="
echo "エンドポイント: ${MINIO_ENDPOINT}"
echo "バケット名:     ${MINIO_BUCKET}"
echo ""

# MinIO接続待機
echo "--- MinIO接続待機中 ---"
MAX_RETRIES=30
RETRY_COUNT=0

while ! docker compose exec minio mc alias set local http://localhost:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" 2>/dev/null; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "エラー: MinIOへの接続がタイムアウトしました（${MAX_RETRIES}回リトライ）"
        exit 1
    fi
    echo "  リトライ ${RETRY_COUNT}/${MAX_RETRIES}..."
    sleep 2
done

echo "--- MinIO接続成功 ---"

# バケット作成
echo "--- バケット作成中: ${MINIO_BUCKET} ---"
docker compose exec minio mc mb "local/${MINIO_BUCKET}" --ignore-existing

# バケット一覧の確認
echo ""
echo "--- 現在のバケット一覧 ---"
docker compose exec minio mc ls local/

echo ""
echo "=============================================="
echo "MinIO バケット初期化完了"
echo "=============================================="
