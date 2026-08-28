#!/bin/bash
# ==============================================================================
# Dockerイメージエクスポートスクリプト
# ==============================================================================
#
# 概要:
#   閉域網への移送用に全必要Dockerイメージをアーカイブ化します。
#   オンライン開発環境で実行し、生成されたアーカイブを物理ストレージ経由で
#   閉域サーバーへ移送してください。
#
# 使用方法:
#   bash scripts/export-images.sh [出力ディレクトリ]
#
# 閉域サーバーでのロード方法:
#   bash scripts/export-images.sh --load [アーカイブディレクトリ]
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
check_cmd gzip

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 移送対象イメージ一覧
IMAGES=(
    "nginx:1.25-alpine"
    "ghcr.io/danny-avila/librechat-dev-api:latest"
    "mongo:6.0"
    "minio/minio:RELEASE.2025-09-07T16-13-09Z"
    "minio/mc:latest"
    "redis:7.2-alpine"
    "rce_lc-code-api:latest"
    "rce_lc-service-worker:latest"
    "rce_lc-sandbox-runner:latest"
    "rce_lc-egress-gateway:latest"
    "rce_lc-file-server:latest"
    "rce_lc-tool-call-server:latest"
)

# --------------------------------------------------------------------------
# ロードモード（閉域サーバー側で実行）
# --------------------------------------------------------------------------
if [ "${1:-}" = "--load" ]; then
    ARCHIVE_DIR="${2:-.}"
    echo "=============================================="
    echo "Dockerイメージロード（閉域サーバー）"
    echo "=============================================="
    echo "アーカイブディレクトリ: ${ARCHIVE_DIR}"
    echo ""

    for archive in "${ARCHIVE_DIR}"/*.tar.gz; do
        if [ -f "$archive" ]; then
            echo "--- ロード中: $(basename "$archive") ---"
            docker load -i "$archive"
            echo ""
        fi
    done

    echo "=============================================="
    echo "全イメージのロード完了"
    echo "=============================================="
    docker images
    exit 0
fi

# --------------------------------------------------------------------------
# エクスポートモード（オンライン開発環境で実行）
# --------------------------------------------------------------------------
OUTPUT_DIR="${1:-${PROJECT_DIR}/image-archives}"
mkdir -p "${OUTPUT_DIR}"

echo "=============================================="
echo "Dockerイメージエクスポート"
echo "=============================================="
echo "出力ディレクトリ: ${OUTPUT_DIR}"
echo "対象イメージ数:   $((${#IMAGES[@]} + 1))"
echo ""

# Step 1: 全コンテナのビルド & プル
echo "=== Step 1: docker compose による全イメージのビルド & プル ==="
docker compose -f "${PROJECT_DIR}/docker-compose.yml" build
docker compose -f "${PROJECT_DIR}/docker-compose.yml" pull || true
echo ""

# Step 2: イメージのエクスポート
echo "=== Step 2: イメージのアーカイブ化 ==="
for image in "${IMAGES[@]}"; do
    # イメージ名からファイル名を生成（/ と : を _ に置換）
    filename=$(echo "${image}" | tr '/:' '__')
    archive_path="${OUTPUT_DIR}/${filename}.tar.gz"

    echo "--- エクスポート中: ${image} → ${archive_path} ---"
    docker save "${image}" | gzip > "${archive_path}"
    echo "  サイズ: $(du -h "${archive_path}" | cut -f1)"
    echo ""
done

# カスタムWorkerイメージのエクスポート（設定されている場合）
if [ -n "${CUSTOM_WORKER_IMAGE:-}" ]; then
    echo "--- エクスポート中: ${CUSTOM_WORKER_IMAGE} ---"
    archive_path="${OUTPUT_DIR}/rce-code-worker__enterprise-v1.tar.gz"
    docker save "${CUSTOM_WORKER_IMAGE}" | gzip > "${archive_path}"
    echo "  サイズ: $(du -h "${archive_path}" | cut -f1)"
fi

# 合計サイズの表示
echo ""
echo "=============================================="
echo "エクスポート完了"
echo "=============================================="
echo ""
echo "アーカイブ一覧:"
ls -lh "${OUTPUT_DIR}"/*.tar.gz
echo ""
TOTAL_SIZE=$(du -sh "${OUTPUT_DIR}" | cut -f1)
echo "合計サイズ: ${TOTAL_SIZE}"
echo ""
echo "次の手順:"
echo "  1. ${OUTPUT_DIR}/ 内のアーカイブを物理ストレージにコピー"
echo "  2. 閉域サーバーへ移送"
echo "  3. 閉域サーバーで以下を実行:"
echo "     bash scripts/export-images.sh --load ${OUTPUT_DIR}"
