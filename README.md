# shared-workflows

GitHub Actions の Reusable Workflows を集約するリポジトリ。
複数リポジトリから共通のワークフローを呼び出すことで、CI/CD の重複を排除する。

## 構成

```
shared-workflows/
├── .github/
│   ├── workflows/       # CI + Reusable Workflows + Caller
│   │   ├── claude.yml          # Reusable: Claude Code Action
│   │   ├── claude-caller.yml   # Caller: 本リポ用（動作確認）
│   │   └── ci.yml              # CI: shellcheck + actionlint
│   └── scripts/         # ワークフローから呼ばれるスクリプト
│       ├── auto-fix/    # Copilot Auto Fix 用スクリプト
│       ├── post-merge/  # マージ後処理スクリプト
│       └── late-review-scanner/  # 事後レビュースキャナー
├── docs/
│   └── specs/           # ワークフロー仕様書
├── examples/            # 各リポに配置するサンプル
│   ├── caller-workflows/# caller YAML のサンプル
│   ├── prompts/         # プロンプトテンプレートのサンプル
│   └── claude/          # Claude Code 設定のサンプル
├── scripts/             # リポジトリ管理用スクリプト
│   └── setup-labels.sh  # ラベル一括作成
└── README.md
```

## Reusable Workflows

| ワークフロー | 概要 | 必須 Secrets |
|---|---|---|
| `claude.yml` | Claude Code Action（`@claude` メンション応答 + `auto-implement` 自動実装） | `CLAUDE_CODE_OAUTH_TOKEN`, `REPO_OWNER_PAT` |
| `copilot-auto-fix.yml` | Copilot レビュー指摘の自動修正 + マージ | `CLAUDE_CODE_OAUTH_TOKEN`, `REPO_OWNER_PAT` |
| `post-merge.yml` | マージ後の自動処理（review-batch Issue 更新） | — |
| `late-review-scanner.yml` | マージ済み PR の事後レビュー指摘を検出・集約 | `REPO_OWNER_PAT` |

本リポにも caller（`claude-caller.yml`）を配置しており、`@claude` メンションで動作確認が可能。

## 仕様書

| 仕様書 | 概要 |
|---|---|
| [auto-progress](docs/specs/auto-progress.md) | 自動進行管理パイプライン（Issue → 実装 → レビュー → マージ） |
| [claude-code-actions](docs/specs/claude-code-actions.md) | `@claude` メンションによる Claude Code 呼び出し |
| [copilot-auto-fix](docs/specs/copilot-auto-fix.md) | Copilot レビュー指摘の自動修正 + マージ |
| [late-review-scanner](docs/specs/late-review-scanner.md) | マージ済み PR の事後レビュー指摘の定期検出・集約 |

## 推奨ブランチ構成

自動パイプラインは PR の base ブランチにマージする。マージ先が本番ブランチ（`main`）だと、自動マージが直接本番に入るリスクがある。

git-flow のように開発統合ブランチ（`develop` 等）を分離し、自動マージ先を本番以外のブランチに限定することで、`main` の安定性を保護できる。

## セットアップガイド

### 1. Secrets の設定

呼び出し側リポジトリに以下の Secrets を設定する:

| Secret | 必須 | 説明 |
|--------|:----:|------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Claude Code Action の認証トークン |
| `REPO_OWNER_PAT` | Yes | ワークフロー連鎖・PR 作成用の Personal Access Token |

設定場所: リポジトリの Settings > Secrets and variables > Actions > **New repository secret**

#### CLAUDE_CODE_OAUTH_TOKEN の取得

Claude Code の OAuth トークン。ローカル環境で以下を実行して取得する:

```bash
claude setup-token
```

表示されたトークン値をリポジトリ Secret に設定する。

#### REPO_OWNER_PAT の取得

GitHub Personal Access Token。ワークフロー連鎖（GITHUB_TOKEN で作成した PR は他のワークフローをトリガーしない制約の回避）と PR 作成に使用する。

**Fine-grained token（推奨）:**

1. GitHub > Settings > Developer settings > [Personal access tokens > Fine-grained tokens](https://github.com/settings/tokens?type=beta)
2. **Generate new token** をクリック
3. Token name: 任意（例: `shared-workflows-pat`）
4. Repository access: **All repositories** または対象リポジトリを個別選択
5. Permissions:
   - **Contents**: Read and write
   - **Issues**: Read and write
   - **Pull requests**: Read and write
   - **Workflows**: Read and write
6. **Generate token** → 表示されたトークン値をリポジトリ Secret に設定

**Classic token:**

1. GitHub > Settings > Developer settings > [Personal access tokens > Tokens (classic)](https://github.com/settings/tokens)
2. **Generate new token (classic)** をクリック
3. Scopes: `repo`（全チェック）+ `workflow`
4. **Generate token** → 表示されたトークン値をリポジトリ Secret に設定

> **注意**: トークン値は生成時にのみ表示される。紛失した場合は再発行が必要。

### 2. Variables の設定

| Variable | デフォルト | 説明 |
|----------|-----------|------|
| `AUTO_MERGE_ENABLED` | `false` | `true` で自動マージ有効化（それ以外はドライラン） |
| `COPILOT_REVIEW_TIMEOUT` | `600` | Copilot レビュー待機の最大秒数 |

### 3. ラベルの作成

このリポジトリの `scripts/setup-labels.sh` を使い、呼び出し側リポジトリにラベルを一括作成する。

#### リポジトリのクローン

```bash
git clone https://github.com/becky3/shared-workflows.git
cd shared-workflows
```

#### ラベルの適用

```bash
bash scripts/setup-labels.sh owner/repo
```

対象リポジトリごとに `owner/repo` を変えて実行する。既存のラベルはスキップされる。

#### 必要な権限

- `gh` CLI が認証済みであること（`gh auth status` で確認）
- 対象リポジトリへの Issues の write 権限が必要

### 4. 呼び出し側ワークフローの配置

`examples/caller-workflows/` に caller YAML のサンプルがある。
呼び出し側リポジトリの `.github/workflows/` にコピーし、`<YOUR_USERNAME>` 等のプレースホルダーを置き換えて使用する。

| サンプル | 対応する Reusable Workflow | 概要 |
|---------|--------------------------|------|
| `claude.yml` | `.github/workflows/claude.yml` | Claude Code Action（メンション + auto-implement） |
| `copilot-auto-fix.yml` | `.github/workflows/copilot-auto-fix.yml` | Copilot レビュー自動修正 + マージ |
| `post-merge.yml` | `.github/workflows/post-merge.yml` | マージ後の review-batch Issue 更新 |
| `late-review-scanner.yml` | `.github/workflows/late-review-scanner.yml` | 事後レビュー指摘の検出・集約 |

### 5. プロンプト・設定ファイルの配置

以下のファイルは各リポジトリ固有のため、呼び出し側に配置する:

- `.github/prompts/auto-fix-check-pr.md` — レビュー指摘対応プロンプト（`examples/prompts/` にサンプルあり）
- `.claude/CLAUDE-auto-progress.md` — GA 環境専用ルール（`examples/claude/` にサンプルあり）

## バージョニング

呼び出し側は `@main` で参照する:

```yaml
uses: becky3/shared-workflows/.github/workflows/<workflow>.yml@main
```
