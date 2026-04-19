# Quality Check

## 概要

PR に対して品質チェック（テスト・lint・型チェック・markdownlint）を実行する reusable workflow。各プロジェクトは caller workflow から呼び出し、branch protection rule と組み合わせることでエラーがある状態でのマージをブロックできる。

## 背景

- エージェントが品質ゲートのテスト工程をスキップ、または既存エラーを「対応範囲外」として見逃したまま PR をマージするケースがある
- CI レベルでマージをブロックする最終防衛線が必要
- プロジェクトごとにチェック内容が異なるため、コマンド文字列を input で受け取る汎用設計とする

## 制約

### 実行環境

- ランナー: `ubuntu-latest`
- Python 環境: `actions/setup-python` でバージョンを指定
- Node.js 環境: markdownlint ジョブでのみ `actions/setup-node` を使用

### セキュリティ

- テスト実行に認証は不要（Secrets の受け渡しなし）
- 呼び出し側リポジトリのコードのみを対象とする

### ジョブ独立性

- 各チェック（lint・型チェック・テスト・markdownlint）は独立したジョブとして並列実行する
- 1 つのジョブが失敗しても他のジョブは最後まで実行される
- 空コマンドが指定されたジョブはスキップする

## トリガー条件

`workflow_call` による reusable workflow として呼び出される。

呼び出し側が設定する典型的なトリガー:

| イベント | 用途 |
| --- | --- |
| `pull_request` | PR 作成・更新時の自動チェック |

### inputs

| input | 型 | 必須 | デフォルト | 説明 |
| --- | --- | --- | --- | --- |
| `python_version` | string | No | `"3.11"` | Python バージョン |
| `install_command` | string | Yes | — | 依存インストールコマンド（例: `uv sync`） |
| `test_command` | string | No | `""` | テストコマンド（例: `uv run pytest`）。空でスキップ |
| `lint_command` | string | No | `""` | lint コマンド（例: `uv run ruff check src/ tests/`）。空でスキップ |
| `typecheck_command` | string | No | `""` | 型チェックコマンド（例: `uv run mypy src/`）。空でスキップ |
| `markdownlint` | boolean | No | `false` | markdownlint を実行するか |
| `markdownlint_globs` | string | No | `"**/*.md"` | markdownlint の対象 glob パターン |

## 処理フロー

### ジョブ構成

4 つの独立ジョブで構成し、並列実行する。

1. **lint** — `lint-command` が空でない場合に実行
   - チェックアウト
   - Python セットアップ
   - 依存インストール（`install-command`）
   - lint 実行（`lint-command`）

2. **typecheck** — `typecheck-command` が空でない場合に実行
   - チェックアウト
   - Python セットアップ
   - 依存インストール（`install-command`）
   - 型チェック実行（`typecheck-command`）

3. **test** — `test-command` が空でない場合に実行
   - チェックアウト
   - Python セットアップ
   - 依存インストール（`install-command`）
   - テスト実行（`test-command`）

4. **markdownlint** — `markdownlint` が `true` の場合に実行
   - チェックアウト
   - Node.js セットアップ
   - markdownlint-cli2 インストール
   - markdownlint 実行（`markdownlint-globs` の対象）

### 共通ステップ

lint・typecheck・test の 3 ジョブは以下の共通パターンに従う:

1. `actions/checkout@v4`
2. `astral-sh/setup-uv` で uv をインストール
3. `actions/setup-python@v5`（`python-version` で指定）
4. 依存インストール（`install-command` を実行）
5. 各コマンド実行

uv を使用しないプロジェクトではステップ 2 は無害（uv がインストールされるだけで使われない）。

## 出力

### 成功時

- 全ジョブが正常終了し、PR の status check が緑になる
- branch protection rule で必須チェックに指定されている場合、マージが可能になる

### 失敗時

- 失敗したジョブの status check が赤になる
- 他のジョブは独立して最後まで実行される（失敗の全体像を把握できる）
- branch protection rule で必須チェックに指定されている場合、マージがブロックされる

## 関連ドキュメント

- [claude-code-actions](claude-code-actions.md) — Claude Code Action ワークフロー
- [auto-progress](auto-progress.md) — 自動進行管理パイプライン
