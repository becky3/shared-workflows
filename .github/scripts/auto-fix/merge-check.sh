#!/usr/bin/env bash
# Merge check — マージ条件6項目（PR状態・レビュー・CI・コンフリクト・ラベル・禁止パターン）のチェック
#
# 入力（環境変数）:
#   PR_NUMBER       — 対象PR番号
#   GITHUB_OUTPUT   — GitHub Actions 出力ファイル
#   GH_TOKEN        — GitHub トークン（env経由で gh CLI が自動参照）
#   GH_REPO         — 対象リポジトリ（owner/repo）
#   EXCLUDE_CHECK   — （任意）CI チェック除外名。自ワークフローの自己参照防止用
#   FORBIDDEN_DETECTED — （任意）禁止パターン検出結果。"true" の場合マージ拒否
#   FORBIDDEN_FILES  — （任意）禁止パターン該当ファイル一覧（multiline）。REASONS に含める
#   REVIEW_SKIPPED  — （任意）"true" の場合、レビュースキップ（タイムアウト）として条件2をスキップ
#
# 出力（$GITHUB_OUTPUT）:
#   merge_ready     — "true" / "false"
#   reasons         — マージ不可の理由（multiline、merge_ready=false の場合のみ）
#
# エラー方針: API失敗 → 安全側に倒してマージ拒否

set -euo pipefail
# 動的パス解決のため静的解析不可
# shellcheck disable=SC1091
source "$(dirname "$0")/_common.sh"

require_env PR_NUMBER GITHUB_OUTPUT

MERGE_READY=true
REASONS=""

# 条件1: PR が OPEN 状態（マージ済み・クローズ済みの PR はスキップ）
if ! PR_STATE=$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>&1); then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ GitHub API error: Cannot verify PR state"
  echo "::warning::Failed to check PR state (API error): $PR_STATE"
  echo "❌ Condition 1: API error (cannot verify state)"
elif [ "$PR_STATE" != "OPEN" ]; then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ PR is $PR_STATE (expected OPEN)"
  echo "❌ Condition 1: PR is $PR_STATE"
else
  echo "✅ Condition 1: PR is OPEN"
fi

# ラベル取得（条件2のレビュースキップ判定と条件5の auto:failed 判定で共用）
LABELS_FETCHED=false
if LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name' 2>&1); then
  LABELS_FETCHED=true
else
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ GitHub API error: Cannot verify labels"
  echo "::warning::Failed to retrieve labels (API error): $LABELS"
  echo "❌ Label check: API error"
  LABELS=""
fi

# 条件2: レビュー指摘ゼロ（既に has_issues=false で確認済み）
# レビュースキップ時（auto:review-skipped ラベルあり）は条件2をスキップ
# REVIEW_SKIPPED 環境変数が設定されていない場合はラベルにフォールバック
if [ "${REVIEW_SKIPPED:-}" = "true" ] || echo "$LABELS" | grep -q "^auto:review-skipped$"; then
  echo "⏭️ Condition 2: Review skipped (timeout) — waived"
else
  echo "✅ Condition 2: No review issues"
fi

# 条件3: CI全チェック通過（GitHub API の statusCheckRollup を使用）
# EXCLUDE_CHECK が設定されている場合、そのチェック名を除外する
# （自ワークフローの実行中チェックを除外するため。copilot-auto-fix.yml から呼ばれる場合に使用）
# gh pr view --jq は --arg 非対応のため、一時環境変数 + env オブジェクト経由で jq に渡す
EXCLUDE_NAME="${EXCLUDE_CHECK:-}"
# CI チェックの状態を分類: 失敗・実行中・合計をそれぞれカウント
# CI 完了待機ステップ（wait-for-ci.sh）を経由していれば実行中は 0 のはず
# jq 内の $total, $pending, $failed は jq 変数（bash 変数ではない）
# shellcheck disable=SC2016
if ! CI_RESULT=$(EXCLUDE_NAME="$EXCLUDE_NAME" gh pr view "$PR_NUMBER" --json statusCheckRollup --jq '
  if .statusCheckRollup == null then
    "no_checks"
  else
    (
      [.statusCheckRollup[] |
        select(if env.EXCLUDE_NAME != "" then (.name | contains(env.EXCLUDE_NAME)) | not else true end)
      ] | length
    ) as $total |
    (
      [.statusCheckRollup[] |
        select(if env.EXCLUDE_NAME != "" then (.name | contains(env.EXCLUDE_NAME)) | not else true end) |
        select(
          (has("status") and .status != "COMPLETED") or
          (has("state") and (.state == "PENDING" or .state == "EXPECTED"))
        )
      ] | length
    ) as $pending |
    (
      [.statusCheckRollup[] |
        select(if env.EXCLUDE_NAME != "" then (.name | contains(env.EXCLUDE_NAME)) | not else true end) |
        select(
          (has("status") and .status == "COMPLETED" and .conclusion != "SUCCESS" and .conclusion != "NEUTRAL" and .conclusion != "SKIPPED") or
          (has("state") and .state != "SUCCESS" and .state != "NEUTRAL" and .state != "PENDING" and .state != "EXPECTED")
        )
      ] | length
    ) as $failed |
    "\($failed):\($pending):\($total)"
  end
' 2>&1); then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ GitHub API error: Cannot verify CI status"
  echo "::warning::Failed to check CI status (API error, not CI failure): $CI_RESULT"
  echo "❌ Condition 3: API error (not CI failure)"
elif [ "$CI_RESULT" = "no_checks" ]; then
  echo "✅ Condition 3: No CI checks configured"
else
  FAILED="${CI_RESULT%%:*}"
  REST="${CI_RESULT#*:}"
  PENDING="${REST%%:*}"
  TOTAL="${REST#*:}"

  if [ "$FAILED" = "0" ] && [ "$PENDING" = "0" ]; then
    echo "✅ Condition 3: CI checks passed ($TOTAL check(s))"
  elif [ "$PENDING" != "0" ]; then
    MERGE_READY=false
    REASONS="${REASONS}\n- ❌ CI checks still in progress ($PENDING pending, $FAILED failed out of $TOTAL)"
    echo "❌ Condition 3: CI checks still in progress ($PENDING pending)"
  else
    MERGE_READY=false
    REASONS="${REASONS}\n- ❌ CI checks failed ($FAILED failed out of $TOTAL)"
    echo "❌ Condition 3: CI checks failed ($FAILED failed)"
  fi
fi

# 条件4: コンフリクトなし（方針: 一時的API障害 → 安全側に倒してマージ拒否）
if ! MERGEABLE=$(gh pr view "$PR_NUMBER" --json mergeable --jq '.mergeable' 2>&1); then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ GitHub API error: Cannot verify mergeable status"
  echo "::warning::Failed to check mergeable status (API error): $MERGEABLE"
  echo "❌ Condition 4: API error (not conflict)"
elif [ "$MERGEABLE" != "MERGEABLE" ]; then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ PR has conflicts (status: $MERGEABLE)"
  echo "❌ Condition 4: Conflicts detected"
else
  echo "✅ Condition 4: No conflicts"
fi

# 条件5: auto:failed ラベルなし（LABELS は条件2の前に取得済み）
if [ "$LABELS_FETCHED" != "true" ]; then
  echo "❌ Condition 5: Skipped (label fetch failed earlier)"
elif echo "$LABELS" | grep -q "^auto:failed$"; then
  MERGE_READY=false
  REASONS="${REASONS}\n- ❌ auto:failed label present"
  echo "❌ Condition 5: auto:failed label found"
else
  echo "✅ Condition 5: No auto:failed label"
fi

# 条件6: 禁止パターンなし（auto-fix は続行させるが、マージのみブロック）
if [ "${FORBIDDEN_DETECTED:-}" = "true" ]; then
  MERGE_READY=false
  FILE_LIST=""
  if [ -n "${FORBIDDEN_FILES:-}" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      FILE_LIST="${FILE_LIST}\n  - $f"
    done <<< "$FORBIDDEN_FILES"
  fi
  REASONS="${REASONS}\n- ❌ Forbidden patterns detected (manual merge required)${FILE_LIST}"
  echo "❌ Condition 6: Forbidden patterns detected"
else
  echo "✅ Condition 6: No forbidden patterns"
fi

echo "merge_ready=$MERGE_READY" >> "$GITHUB_OUTPUT"

if [ "$MERGE_READY" = "true" ]; then
  echo "All merge conditions met"
else
  echo "Merge conditions not met"
  {
    echo "reasons<<EOF"
    printf '%b\n' "$REASONS"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi
