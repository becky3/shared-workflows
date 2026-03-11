#!/usr/bin/env bash
# setup.sh — 呼び出し側リポジトリの auto-implement パイプラインを一括セットアップ
#
# 使い方:
#   ./scripts/setup.sh <owner/repo> <github_username> [--force]
#
# 処理内容:
#   1. ラベル一括作成
#   2. caller workflow 4ファイルのコピー
#   3. プロンプトテンプレートのコピー
#   4. GA 環境ルールのコピー
#   5. Secrets 設定状況の検証
#
# オプション:
#   --force  既存ファイルを上書きする（デフォルトはスキップ）

set -euo pipefail

# ─── 引数解析 ───────────────────────────────────────────────────

FORCE=false
REPO=""
USERNAME=""

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *)
      if [ -z "$REPO" ]; then
        REPO="$arg"
      elif [ -z "$USERNAME" ]; then
        USERNAME="$arg"
      else
        echo "Error: unexpected argument '$arg'"
        echo "Usage: $0 <owner/repo> <github_username> [--force]"
        echo "Example: $0 becky3/ai-assistant becky3"
        exit 1
      fi
      ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$USERNAME" ]; then
  echo "Usage: $0 <owner/repo> <github_username> [--force]"
  echo "Example: $0 becky3/ai-assistant becky3"
  exit 1
fi

# owner/repo 形式のバリデーション
if [[ "$REPO" != */* ]]; then
  echo "Error: repository must be in 'owner/repo' format (got: '$REPO')"
  exit 1
fi

# shared-workflows リポジトリのルートを特定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 呼び出し側リポジトリのローカルパスを特定
# owner/repo の repo 部分を取得
REPO_NAME="${REPO#*/}"
# shared-workflows と同階層にあると仮定
REPO_ROOT="$(cd "$SW_ROOT/.." && pwd)/$REPO_NAME"

if [ ! -d "$REPO_ROOT" ]; then
  echo "Error: Target repository not found at $REPO_ROOT"
  echo "Expected the repository to be cloned alongside shared-workflows."
  exit 1
fi

echo "=== shared-workflows setup ==="
echo "Target: $REPO ($REPO_ROOT)"
echo "Username: $USERNAME"
echo "Force: $FORCE"
echo ""

# ─── カウンタ ───────────────────────────────────────────────────

TOTAL_CREATED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

# ─── ユーティリティ ─────────────────────────────────────────────

# ファイルをコピーする（プレースホルダー置換あり）
# copy_file <src> <dst> [placeholder_key placeholder_value ...]
copy_file() {
  local src="$1"
  local dst="$2"
  shift 2

  local dst_dir
  dst_dir="$(dirname "$dst")"

  if [ -f "$dst" ] && [ "$FORCE" = false ]; then
    echo "  ~ $(basename "$dst") (already exists)"
    TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
    return 0
  fi

  mkdir -p "$dst_dir"

  if [ "$#" -gt 0 ]; then
    # プレースホルダー置換してコピー
    local content
    content="$(cat "$src")"
    while [ "$#" -ge 2 ]; do
      local key="$1"
      local value="$2"
      content="${content//$key/$value}"
      shift 2
    done
    printf '%s\n' "$content" > "$dst"
  else
    cp "$src" "$dst"
  fi

  echo "  + $(basename "$dst")"
  TOTAL_CREATED=$((TOTAL_CREATED + 1))
}

# ─── 1. ラベル作成 ──────────────────────────────────────────────

echo "--- Labels ---"

LABEL_SCRIPT="$SCRIPT_DIR/setup-labels.sh"
if [ -f "$LABEL_SCRIPT" ]; then
  # setup-labels.sh の出力をインデントして表示
  if bash "$LABEL_SCRIPT" "$REPO"; then
    : # 成功（カウントは setup-labels.sh 側で表示済み）
  else
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
else
  echo "  ! setup-labels.sh not found at $LABEL_SCRIPT"
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
fi

# ─── 2. Caller Workflows ───────────────────────────────────────

echo ""
echo "--- Caller Workflows (.github/workflows/) ---"

# claude.yml にはプレースホルダー置換が必要
copy_file \
  "$SW_ROOT/examples/caller-workflows/claude.yml" \
  "$REPO_ROOT/.github/workflows/claude.yml" \
  "<YOUR_USERNAME>" "$USERNAME"

# 残り3ファイルはそのままコピー
copy_file \
  "$SW_ROOT/examples/caller-workflows/copilot-auto-fix.yml" \
  "$REPO_ROOT/.github/workflows/copilot-auto-fix.yml"

copy_file \
  "$SW_ROOT/examples/caller-workflows/post-merge.yml" \
  "$REPO_ROOT/.github/workflows/post-merge.yml"

copy_file \
  "$SW_ROOT/examples/caller-workflows/late-review-scanner.yml" \
  "$REPO_ROOT/.github/workflows/late-review-scanner.yml"

# ─── 3. プロンプトテンプレート ──────────────────────────────────

echo ""
echo "--- Prompts (.github/prompts/) ---"

copy_file \
  "$SW_ROOT/examples/prompts/auto-fix-check-pr.md" \
  "$REPO_ROOT/.github/prompts/auto-fix-check-pr.md"

# ─── 4. GA 環境ルール ──────────────────────────────────────────

echo ""
echo "--- Claude Config (.claude/) ---"

copy_file \
  "$SW_ROOT/examples/claude/CLAUDE-auto-progress.md" \
  "$REPO_ROOT/.claude/CLAUDE-auto-progress.md"

# ─── 5. Secrets 検証 ────────────────────────────────────────────

echo ""
echo "--- Secrets Check ---"

SECRETS_OK=true

for SECRET_NAME in CLAUDE_CODE_OAUTH_TOKEN REPO_OWNER_PAT; do
  # gh secret list で確認（設定済みなら名前が表示される）
  if gh secret list --repo "$REPO" 2>/dev/null | grep -q "^${SECRET_NAME}[[:space:]]"; then
    echo "  ✓ $SECRET_NAME (configured)"
  else
    echo "  ⚠ $SECRET_NAME (NOT configured)"
    SECRETS_OK=false
  fi
done

if [ "$SECRETS_OK" = false ]; then
  echo ""
  echo "WARNING: Some required secrets are not configured."
  echo "Set them in: Settings > Secrets and variables > Actions > New repository secret"
  echo "See README.md for details on obtaining these tokens."
fi

# ─── サマリ ─────────────────────────────────────────────────────

echo ""
echo "=== Done ==="
echo "  created=$TOTAL_CREATED, skipped=$TOTAL_SKIPPED, failed=$TOTAL_FAILED"

if [ "$TOTAL_FAILED" -gt 0 ]; then
  exit 1
fi
