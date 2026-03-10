#!/usr/bin/env bash
# Late Review Scanner — マージ済みPRの未解決レビュースレッドを検出し集約Issueに記録
#
# 設計書: docs/specs/late-review-scanner.md
#
# 必須環境変数:
#   GH_TOKEN        — GitHub トークン
#   GH_REPO         — リポジトリ (owner/repo)
#   GITHUB_REPOSITORY — リポジトリ (owner/repo)（GraphQL用）
#
# 任意環境変数:
#   SCAN_HOURS      — スキャン範囲（デフォルト: 24）
#
# エラーハンドリング方針:
#   集約Issue作成失敗        → exit 1（必須リソース）
#   PR個別のAPI障害          → warning で次のPRに継続
#   スレッド resolve 失敗     → warning で続行（次回再検出）
#   認証/権限エラー           → exit 1（即停止）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 動的パス解決のため静的解析不可
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../auto-fix/_common.sh"

require_env GH_TOKEN GH_REPO GITHUB_REPOSITORY

SCAN_HOURS="${SCAN_HOURS:-24}"
if ! validate_numeric "$SCAN_HOURS" "SCAN_HOURS"; then
  echo "::warning::Invalid SCAN_HOURS, using default 24"
  SCAN_HOURS=24
fi

REPO_OWNER="${GITHUB_REPOSITORY%%/*}"
REPO_NAME="${GITHUB_REPOSITORY#*/}"
LABEL="auto:late-review"

# --- THREAD_ID フォーマット検証関数 ---
# GitHub thread ID は Base64 エンコードされるため = も許容
validate_thread_id() {
  local id="$1"
  if ! [[ "$id" =~ ^[A-Za-z0-9_=-]+$ ]]; then
    echo "::warning::Invalid thread ID format: $id"
    return 1
  fi
}

# --- 1. マージ済みPR取得 ---
SINCE=$(date -u -d "${SCAN_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)
echo "Scanning for merged PRs since $SINCE (last ${SCAN_HOURS}h)..."

MERGED_PRS=""
if ! MERGED_PRS=$(gh pr list --repo "$GH_REPO" --state merged \
  --json number,title,mergedAt --limit 100 \
  --jq "[.[] | select(.mergedAt >= \"$SINCE\")] | .[] | \"\(.number)\t\(.title)\"" 2>&1); then
  # 認証エラーチェック
  if echo "$MERGED_PRS" | grep -qiE '(401|403|authentication|forbidden|resource not accessible)'; then
    echo "::error::Authentication/permission error: $MERGED_PRS"
    exit 1
  fi
  echo "::warning::Failed to list merged PRs: $MERGED_PRS"
  exit 0
fi

if [ -z "$MERGED_PRS" ]; then
  echo "No merged PRs found in the last ${SCAN_HOURS}h. Done."
  exit 0
fi

PR_COUNT=$(echo "$MERGED_PRS" | wc -l)
echo "Found $PR_COUNT merged PR(s)"

# --- 2-3. 各PRの未解決スレッドを収集 ---
# 結果を一時ファイルに蓄積（サブシェル変数スコープ対策）
RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

TOTAL_THREADS=0

while IFS=$'\t' read -r PR_NUMBER PR_TITLE; do
  [ -z "$PR_NUMBER" ] && continue

  echo ""
  echo "--- PR #$PR_NUMBER: $PR_TITLE ---"

  # GraphQL で未解決レビュースレッドを取得
  # shellcheck disable=SC2016
  THREADS_JSON=""
  if ! THREADS_JSON=$(gh api graphql -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              comments(first: 1) {
                nodes {
                  url
                }
              }
            }
          }
        }
      }
    }
  ' -f owner="$REPO_OWNER" -f name="$REPO_NAME" -F number="$PR_NUMBER" \
    --jq '
      .data.repository.pullRequest.reviewThreads.nodes
      | [.[] | select(.isResolved == false)]
      | map({id: .id, url: .comments.nodes[0].url})
    ' 2>&1); then
    # 認証エラーチェック
    if echo "$THREADS_JSON" | grep -qiE '(401|403|authentication|forbidden|resource not accessible)'; then
      echo "::error::Authentication/permission error: $THREADS_JSON"
      exit 1
    fi
    echo "::warning::Failed to query threads for PR #$PR_NUMBER: $THREADS_JSON"
    continue
  fi

  THREAD_COUNT=$(echo "$THREADS_JSON" | jq 'length' 2>/dev/null)
  if ! validate_numeric "$THREAD_COUNT" "thread count"; then
    echo "::warning::Invalid thread count for PR #$PR_NUMBER: $THREADS_JSON"
    continue
  fi

  if [ "$THREAD_COUNT" -eq 0 ]; then
    echo "No unresolved threads."
    continue
  fi

  echo "Found $THREAD_COUNT unresolved thread(s)"
  TOTAL_THREADS=$((TOTAL_THREADS + THREAD_COUNT))

  # PR情報とスレッドデータを結果ファイルに追記
  echo "$THREADS_JSON" | jq -c --arg pr_number "$PR_NUMBER" --arg pr_title "$PR_TITLE" \
    '{pr_number: $pr_number, pr_title: $pr_title, threads: .}' >> "$RESULTS_FILE"

done <<< "$MERGED_PRS"

# --- 3. 検出がなければ終了 ---
if [ "$TOTAL_THREADS" -eq 0 ]; then
  echo ""
  echo "No unresolved threads found across all PRs. Done."
  exit 0
fi

echo ""
echo "Total unresolved threads: $TOTAL_THREADS"

# --- 4. 集約Issue検索・作成 ---
ISSUE_NUMBER=""
if ! ISSUE_NUMBER=$(gh issue list --repo "$GH_REPO" --label "$LABEL" --state open \
  --json number --jq '.[0].number // empty' 2>&1); then
  echo "::warning::Failed to search for existing issue: $ISSUE_NUMBER"
  ISSUE_NUMBER=""
fi

# 数値バリデーション
if [ -n "$ISSUE_NUMBER" ] && ! validate_numeric "$ISSUE_NUMBER" "ISSUE_NUMBER"; then
  echo "::warning::Unexpected issue number format: '$ISSUE_NUMBER'"
  ISSUE_NUMBER=""
fi

if [ -n "$ISSUE_NUMBER" ]; then
  echo "Found existing late-review issue: #$ISSUE_NUMBER"
else
  echo "No existing late-review issue found. Creating new one."

  DATE=$(date -u +"%Y-%m-%d") || DATE="unknown-date"

  ISSUE_BODY="## 事後レビュー指摘

この Issue はマージ済み PR に対する事後レビュー指摘をまとめたものです。
マージ後にコードが変更されている可能性が高いため、指摘の行番号は参考値です。該当箇所はコードを探索して特定してください。

### 対応方針

- 各コメントの指摘リンクから内容を把握し、該当箇所を探索して修正する
- 大きな変更や判断が必要な場合は別 Issue を切る
- ファイル削除等で対応不可の場合は別 Issue を立てる"

  NEW_ISSUE_URL=""
  if ! NEW_ISSUE_URL=$(gh issue create --repo "$GH_REPO" \
    --title "事後レビュー指摘 (created:${DATE})" \
    --body "$ISSUE_BODY" \
    --label "$LABEL" 2>&1); then
    echo "::error::Failed to create late-review issue: $NEW_ISSUE_URL"
    exit 1
  fi

  # URL形式バリデーション
  if [[ "$NEW_ISSUE_URL" != https://github.com/* ]]; then
    echo "::error::Unexpected issue URL format: $NEW_ISSUE_URL"
    exit 1
  fi

  ISSUE_NUMBER="${NEW_ISSUE_URL##*/}"
  if ! validate_numeric "$ISSUE_NUMBER" "ISSUE_NUMBER"; then
    echo "::error::Could not extract issue number from: $NEW_ISSUE_URL"
    exit 1
  fi

  echo "Created late-review issue: #$ISSUE_NUMBER ($NEW_ISSUE_URL)"

  # ピン留め（ベストエフォート）
  if ! gh_safe_warning gh issue pin "$ISSUE_NUMBER" --repo "$GH_REPO"; then
    echo "Failed to pin issue #$ISSUE_NUMBER (non-critical)"
  else
    echo "Pinned late-review issue #$ISSUE_NUMBER"
  fi
fi

# --- 5. PR単位でコメント追記 ---
COMMENTS_POSTED=0

while IFS= read -r RESULT; do
  [ -z "$RESULT" ] && continue

  PR_NUM=$(echo "$RESULT" | jq -r '.pr_number')
  PR_TTL=$(echo "$RESULT" | jq -r '.pr_title')
  THREAD_IDS=()
  COMMENT_LINKS=""

  while IFS= read -r THREAD; do
    URL=$(echo "$THREAD" | jq -r '.url')
    ID=$(echo "$THREAD" | jq -r '.id')
    COMMENT_LINKS="${COMMENT_LINKS}
- ${URL}"
    THREAD_IDS+=("$ID")
  done < <(echo "$RESULT" | jq -c '.threads[]')

  COMMENT_BODY="## PR #${PR_NUM}: ${PR_TTL}
${COMMENT_LINKS}"

  if ! gh_safe_warning gh issue comment "$ISSUE_NUMBER" --repo "$GH_REPO" --body "$COMMENT_BODY"; then
    echo "Failed to add comment for PR #$PR_NUM"
    continue
  fi

  echo "Added comment for PR #$PR_NUM (${#THREAD_IDS[@]} thread(s))"
  COMMENTS_POSTED=$((COMMENTS_POSTED + 1))

  # --- 6. スレッド resolve ---
  RESOLVED=0
  FAILED=0
  for THREAD_ID in "${THREAD_IDS[@]}"; do
    # フォーマット検証
    if ! validate_thread_id "$THREAD_ID"; then
      FAILED=$((FAILED + 1))
      continue
    fi

    if ! ERROR=$(gh api graphql -f query="
    mutation {
      resolveReviewThread(input: { threadId: \"$THREAD_ID\" }) {
        thread { isResolved }
      }
    }" 2>&1); then
      FAILED=$((FAILED + 1))
      echo "::warning::Failed to resolve thread $THREAD_ID: $ERROR"
    else
      RESOLVED=$((RESOLVED + 1))
    fi
  done

  echo "  Resolved: $RESOLVED, Failed: $FAILED"

done < "$RESULTS_FILE"

# --- サマリー ---
echo ""
echo "=== Summary ==="
echo "PRs with unresolved threads: $COMMENTS_POSTED"
echo "Total unresolved threads: $TOTAL_THREADS"
echo "Issue: #$ISSUE_NUMBER"
