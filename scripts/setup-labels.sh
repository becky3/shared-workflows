#!/usr/bin/env bash
# setup-labels.sh — 自動処理に必要なラベルを一括作成
#
# 使い方:
#   ./scripts/setup-labels.sh owner/repo
#
# 既存ラベルはスキップされる（gh label create の --force なし）

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <owner/repo>"
  echo "Example: $0 becky3/ai-assistant"
  exit 1
fi

REPO="$1"

# ラベル定義: name|color|description
LABELS=(
  "auto-implement|0E8A16|自動実装対象 Issue"
  "auto:pipeline|1D76DB|自動パイプライン処理中"
  "auto:copilot-reviewed|BFD4F2|Copilot レビュー完了"
  "auto:merged|6F42C1|自動マージ済み"
  "auto:failed|D93F0B|自動処理失敗（要手動対応）"
  "auto:review-batch|FBCA04|自動マージレビュー Issue"
  "auto:late-review|C5DEF5|事後レビュー指摘の集約 Issue"
)

echo "Creating labels for $REPO..."

CREATED=0
SKIPPED=0
FAILED=0

for entry in "${LABELS[@]}"; do
  IFS='|' read -r NAME COLOR DESC <<< "$entry"

  if OUTPUT=$(gh label create "$NAME" --repo "$REPO" --color "$COLOR" --description "$DESC" 2>&1); then
    echo "  + $NAME"
    CREATED=$((CREATED + 1))
  elif echo "$OUTPUT" | grep -qi "already exists"; then
    echo "  ~ $NAME (already exists)"
    SKIPPED=$((SKIPPED + 1))
  else
    echo "  ! $NAME (ERROR: $OUTPUT)"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Done: created=$CREATED, skipped/existing=$SKIPPED, failed=$FAILED"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
