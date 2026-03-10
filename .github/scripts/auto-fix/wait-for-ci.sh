#!/usr/bin/env bash
# Wait for CI -- CI チェック完了を sleep ポーリングで待機
#
# 設計書: docs/specs/copilot-auto-fix.md (CI 完了待機)
#
# 入力（環境変数）:
#   PR_NUMBER          -- 対象PR番号（必須）
#   GH_TOKEN           -- GitHub トークン（必須、env経由で gh CLI が自動参照）
#   GH_REPO            -- 対象リポジトリ owner/repo（必須）
#   GITHUB_OUTPUT      -- GitHub Actions 出力ファイル（必須）
#   EXCLUDE_CHECK      -- （任意）除外するチェック名（自ワークフローの自己参照防止用）
#   CI_CHECK_TIMEOUT   -- 最大待機時間（秒）。デフォルト: 300
#
# 出力:
#   ci_ready=true|false（$GITHUB_OUTPUT 経由）
#
# 終了コード:
#   0 — 正常完了 or タイムアウト（ci_ready で呼び出し元が判断）
#   1 — 回復不能エラー（権限/認証エラー）
#
# API エラー:
#   認証/権限エラー → exit 1（即停止）
#   一時的障害 → warning を出力して次のポーリングへ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 動的パス解決のため静的解析不可
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_common.sh"

require_env PR_NUMBER GH_TOKEN GH_REPO GITHUB_OUTPUT

validate_pr_number "$PR_NUMBER" "PR_NUMBER"

TIMEOUT="${CI_CHECK_TIMEOUT:-300}"
POLL_INTERVAL=15

if ! validate_numeric "$TIMEOUT" "CI_CHECK_TIMEOUT"; then
  echo "::warning::Invalid CI_CHECK_TIMEOUT, using default 300"
  TIMEOUT=300
fi

# 最低1回はチェックする（TIMEOUT < POLL_INTERVAL の場合のガード）
MAX_ATTEMPTS=$((TIMEOUT / POLL_INTERVAL))
if [ "$MAX_ATTEMPTS" -lt 1 ]; then
  MAX_ATTEMPTS=1
fi
EXCLUDE_NAME="${EXCLUDE_CHECK:-}"

echo "Polling for CI check completion on PR #$PR_NUMBER (interval: ${POLL_INTERVAL}s, timeout: ${TIMEOUT}s, max attempts: $MAX_ATTEMPTS)"
if [ -n "$EXCLUDE_NAME" ]; then
  echo "Excluding checks containing: $EXCLUDE_NAME"
fi

for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
  echo "--- Attempt $i/$MAX_ATTEMPTS ---"

  # statusCheckRollup を取得し、除外対象を除いた未完了チェックをカウント
  # CheckRun: status が "COMPLETED" でないもの
  # StatusContext: state が "PENDING" または "EXPECTED" のもの
  if ! RESULT=$(EXCLUDE_NAME="$EXCLUDE_NAME" gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '
    if .statusCheckRollup == null then
      "no_checks"
    else
      ([.statusCheckRollup[] |
        select(if env.EXCLUDE_NAME != "" then (.name | contains(env.EXCLUDE_NAME)) | not else true end) |
        select(
          (has("status") and .status != "COMPLETED") or
          (has("state") and (.state == "PENDING" or .state == "EXPECTED"))
        )
      ] | length | tostring)
    end
  ' 2>&1); then
    # 認証/権限エラー → 即停止
    if echo "$RESULT" | grep -qiE "(401|403|authentication|forbidden|resource not accessible)"; then
      echo "::error::Permission/authentication error (non-recoverable): $RESULT"
      output "ci_ready" "false"
      exit 1
    fi
    # 一時的 API 障害 → warning でリトライ
    echo "::warning::Failed to fetch CI status (attempt $i): $RESULT"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [ "$RESULT" = "no_checks" ]; then
    echo "No CI checks configured. Skipping wait."
    output "ci_ready" "true"
    exit 0
  fi

  if ! validate_numeric "$RESULT" "pending check count"; then
    echo "::warning::Invalid check count (attempt $i): $RESULT"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [ "$RESULT" = "0" ]; then
    echo "All CI checks completed on PR #$PR_NUMBER"
    output "ci_ready" "true"
    exit 0
  fi

  echo "$RESULT check(s) still in progress. Waiting ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done

echo "::warning::CI checks did not complete within ${TIMEOUT}s (${MAX_ATTEMPTS} attempts)"
output "ci_ready" "false"
exit 0
