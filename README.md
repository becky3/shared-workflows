# shared-workflows

GitHub Actions の Reusable Workflows を集約するリポジトリ。
複数リポジトリから共通のワークフローを呼び出すことで、CI/CD の重複を排除する。

## 構成

```
shared-workflows/
├── .github/
│   ├── workflows/       # Reusable Workflows 本体
│   └── scripts/         # ワークフローから呼ばれるスクリプト
│       ├── auto-fix/    # Copilot Auto Fix 用スクリプト
│       └── post-merge/  # マージ後処理スクリプト
├── examples/            # 各リポに配置するサンプル
│   ├── prompts/         # プロンプトテンプレートのサンプル
│   └── claude/          # Claude Code 設定のサンプル
├── scripts/             # リポジトリ管理用スクリプト
│   └── setup-labels.sh  # ラベル一括作成
└── README.md
```

## セットアップガイド

### 1. Secrets の設定

呼び出し側リポジトリに以下の Secrets を設定する:

| Secret | 必須 | 説明 |
|--------|:----:|------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Claude Code Action の認証トークン |
| `REPO_OWNER_PAT` | Yes | ワークフロー連鎖・PR 作成用の Personal Access Token |
| `SLACK_WEBHOOK_URL` | No | 失敗時の Slack 通知用 Webhook URL |

### 2. Variables の設定

| Variable | デフォルト | 説明 |
|----------|-----------|------|
| `AUTO_MERGE_ENABLED` | `false` | `true` で自動マージ有効化（それ以外はドライラン） |
| `COPILOT_REVIEW_TIMEOUT` | `600` | Copilot レビュー待機の最大秒数 |

### 3. ラベルの作成

呼び出し側リポジトリで、自動処理に必要なラベルを一括作成する:

```bash
# リポジトリ名を指定して実行
./scripts/setup-labels.sh owner/repo
```

### 4. 呼び出し側ワークフローの配置

`examples/` ディレクトリにサンプルの caller YAML を用意している（Phase3/4 で追加予定）。
呼び出し側リポジトリの `.github/workflows/` にコピーして使用する。

### 5. プロンプト・設定ファイルの配置

以下のファイルは各リポジトリ固有のため、呼び出し側に配置する:

- `.github/prompts/auto-fix-check-pr.md` — レビュー指摘対応プロンプト（`examples/prompts/` にサンプルあり）
- `.claude/CLAUDE-auto-progress.md` — GA 環境専用ルール（`examples/claude/` にサンプルあり）

## バージョニング

呼び出し側は `@main` で参照する:

```yaml
uses: becky3/shared-workflows/.github/workflows/claude.yml@main
```
