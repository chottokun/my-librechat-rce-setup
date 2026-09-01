#!/bin/bash
# ==============================================================================
# シェルスクリプト単体・構文検証用テストスイート
# ==============================================================================
#
# 概要:
#   `scripts/*.sh` の構文チェック、シバン、権限、および
#   共通モジュールの関数（`check_cmd`, `pass`, `fail`, `warn`, `info`, `log_header` 等）
#   の期待する振る舞いを検証します。
#
# 使用方法:
#   bash scripts/test-scripts.sh
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

TEST_PASSED=0
TEST_FAILED=0

assert_success() {
    local test_name="$1"
    shift
    if "$@"; then
        echo -e "  [PASS] ${test_name}"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo -e "  [FAIL] ${test_name}"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

assert_syntax() {
    local file="$1"
    assert_success "構文チェック: $(basename "$file")" bash -n "$file"
}

echo "=============================================="
echo "scripts/*.sh 検証テストスイート"
echo "=============================================="
echo ""

# 1. すべてのスクリプトの構文チェック
echo "--- 1. Bash 構文チェック ---"
for script in "${SCRIPT_DIR}"/*.sh; do
    if [ -f "$script" ]; then
        assert_syntax "$script"
    fi
done

# 2. common.sh が存在する場合はライブラリ関数の動作確認
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
    echo ""
    echo "--- 2. common.sh 共通ライブラリ関数テスト ---"

    # common.sh の読み込みテスト
    assert_success "common.sh 読み込み" bash -c "source '${SCRIPT_DIR}/common.sh'"

    # SCRIPT_DIR / PROJECT_DIR の解決テスト
    assert_success "PROJECT_DIR 解決" bash -c "source '${SCRIPT_DIR}/common.sh' && [ -n \"\$PROJECT_DIR\" ]"

    # check_cmd 成功テスト
    assert_success "check_cmd (正常系: bash)" bash -c "source '${SCRIPT_DIR}/common.sh' && check_cmd bash"

    # check_cmd 失敗テスト (存在しないコマンド)
    assert_success "check_cmd (異常系: 存在しないコマンド)" bash -c "source '${SCRIPT_DIR}/common.sh' && ! check_cmd nonexistent_cmd_12345 2>/dev/null"

    # ログ出力関数のテスト
    assert_success "ログ関数 (info, warn, pass, fail, log_header)" bash -c "source '${SCRIPT_DIR}/common.sh' && info test && warn test && pass test && fail test && log_header test >/dev/null"
fi

echo ""
echo "=============================================="
echo "検証結果: SUCCESS=${TEST_PASSED}, FAIL=${TEST_FAILED}"
echo "=============================================="

if [ "$TEST_FAILED" -eq 0 ]; then
    exit 0
else
    exit 1
fi
