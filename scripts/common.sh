#!/bin/bash
# ==============================================================================
# 共通ライブラリ・ヘルパーモジュール
# ==============================================================================
#
# 概要:
#   プロジェクト内シェルスクリプト共通のコマンドチェック、環境変数読み込み、
#   パス解決、カラー出力、およびロギング関数を提供します。
#
# ==============================================================================

set -euo pipefail

# 1. パス解決
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
export SCRIPT_DIR PROJECT_DIR

# 2. 環境変数の読み込み
if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
fi

# 3. カラー出力定義
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# 4. 共通ヘルパー関数

# コマンド存在チェック
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}エラー: 必須コマンド '$1' が見つかりません。インストールしてください。${NC}" >&2
        return 1
    fi
}

# カウンター用変数（必要に応じて呼び出し元スクリプトで初期化）
PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=${FAIL_COUNT:-0}
WARN_COUNT=${WARN_COUNT:-0}

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    local test_name="$1"
    local reason="${2:-}"
    echo -e "  ${RED}[FAIL]${NC} ${test_name}"
    if [ -n "$reason" ]; then
        echo -e "         ${YELLOW}詳細: ${reason}${NC}"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE} $1 ${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}
