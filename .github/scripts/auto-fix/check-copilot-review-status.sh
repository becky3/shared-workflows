#!/usr/bin/env bash
# check-copilot-review-status -- Copilot 自動レビュー有効判定
#
# リポジトリの ruleset に有効な copilot_code_review ルールがあるかを確認し、
# 標準出力へ "on"（自動レビュー有効）/ "off"（無効）を出力する。
#
# 判定の SSoT は GitHub の実設定（ruleset）そのもの。
# active な ruleset のいずれかに type=copilot_code_review のルールがあれば "on"、
# なければ "off"。
#
# エラー・判定不能時は "on" を出力する（安全側デフォルト。
# 誤って off に倒すと自動レビュー有効なのにレビュー待ちをスキップする恐れがあるため）。
#
# 入力（環境変数）:
#   GH_TOKEN  -- GitHub トークン。未設定時は gh api が認証エラーで失敗し "on" フォールバックになる
#   GH_REPO   -- 対象リポジトリ owner/repo（必須）
#
# 出力:
#   標準出力: "on" または "off"（それ以外は出力しない）
#   診断メッセージ: 標準エラー出力
#
# 注意:
#   --paginate を使用するため ruleset が多いリポジトリでは複数の API 呼び出しが発生する。
#   通常の運用規模（~数十件）では問題にならない。
#
# 終了コード:
#   0 — 常に 0（エラー時は "on" を出力して続行）

set -uo pipefail

NWO="${GH_REPO:-}"

if [ -z "$NWO" ]; then
  echo "::warning::GH_REPO is not set. Defaulting to on." >&2
  echo "on"
  exit 0
fi

# active な ruleset の ID 一覧を取得
# includes_parents=true で組織レベルから継承される ruleset も対象に含める
# （リポジトリレベルに ruleset が無く組織側で copilot_code_review を配布する運用に対応）
# --paginate で全ページを走査する（ruleset が 1 ページ上限を超えても見落とさない）
if ! RULESETS=$(gh api --paginate "repos/$NWO/rulesets?includes_parents=true" \
    --jq '.[] | select(.enforcement=="active") | .id' 2>/dev/null); then
  echo "::warning::Failed to fetch rulesets for $NWO. Defaulting to on." >&2
  echo "on"
  exit 0
fi

if [ -z "$RULESETS" ]; then
  echo "No active rulesets found. Copilot auto-review disabled." >&2
  echo "off"
  exit 0
fi

while IFS= read -r RID; do
  [ -z "$RID" ] && continue
  # ruleset 詳細を取得。取得失敗（権限不足等）は安全側に倒して on を返す
  # （黙って off に倒すと、自動レビュー有効なのにレビュー待ちをスキップする恐れがあるため）
  if HIT=$(gh api "repos/$NWO/rulesets/$RID" \
      --jq '.rules[]? | select(.type=="copilot_code_review") | .type' 2>/dev/null); then
    if [ -n "$HIT" ]; then
      echo "copilot_code_review rule found in ruleset $RID. Copilot auto-review enabled." >&2
      echo "on"
      exit 0
    fi
  else
    echo "::warning::Failed to fetch ruleset $RID details. Defaulting to on." >&2
    echo "on"
    exit 0
  fi
done <<< "$RULESETS"

echo "No copilot_code_review rule found in any active ruleset. Copilot auto-review disabled." >&2
echo "off"
exit 0
