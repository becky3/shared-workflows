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
│   ├── setup.sh         # 統合セットアップ
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

## ブランチ運用

### 本リポジトリ

本リポジトリは **main ブランチのみ**で運用する（develop ブランチは使用しない）。

- 作業ブランチ: `feature/*`, `bugfix/*` を main から作成
- PR の base: `main`
- PR マージで main に反映される。呼び出し側は `@main` で参照しているため即時反映

### 呼び出し側リポジトリへの推奨

自動パイプラインは PR の base ブランチにマージする。マージ先が本番ブランチ（`main`）だと、自動マージが直接本番に入るリスクがある。

git-flow のように開発統合ブランチ（`develop` 等）を分離し、自動マージ先を本番以外のブランチに限定することで、`main` の安定性を保護できる。

## セットアップガイド

### クイックセットアップ（推奨）

統合スクリプトで、ラベル作成・ファイルコピー・プレースホルダー置換・Secrets 検証を一括実行する。

> 前提: 呼び出し側リポジトリと `shared-workflows` を同一の親ディレクトリ直下に clone しておくこと。
>
> ```text
> workdir/
> ├── repo/              # 呼び出し側リポジトリ（ターゲット）
> └── shared-workflows/  # 本リポジトリ
> ```

```bash
# 呼び出し側リポジトリを clone（まだの場合）
git clone https://github.com/owner/repo.git

# 同じ階層に shared-workflows を clone
git clone https://github.com/becky3/shared-workflows.git
cd shared-workflows

bash scripts/setup.sh owner/repo your_github_username
```

別のディレクトリ構成の場合は `--target-dir` でパスを明示指定できる:

```bash
bash scripts/setup.sh owner/repo your_github_username --target-dir /path/to/repo
```

既存ファイルはスキップされる。上書きする場合は `--force` を付ける:

```bash
bash scripts/setup.sh owner/repo your_github_username --force
```

実行後、Secrets が未設定の場合は警告が表示される。下記「Secrets の設定」を参照して設定すること。

### Secrets の設定

呼び出し側リポジトリに以下の Secrets を設定する:

| Secret | 必須 | 説明 |
|--------|:----:|------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Yes | Claude Code Action の認証トークン |
| `REPO_OWNER_PAT` | Yes | ワークフロー連鎖・PR 作成・agent-commons 読み取り用の Personal Access Token |

設定場所: リポジトリの Settings > Secrets and variables > Actions > **New repository secret**

#### CLAUDE_CODE_OAUTH_TOKEN の取得

Claude Code の OAuth トークン。ローカル環境で以下を実行して取得する:

```bash
claude setup-token
```

表示されたトークン値をリポジトリ Secret に設定する。

#### REPO_OWNER_PAT の取得

GitHub Personal Access Token。ワークフロー連鎖（GITHUB_TOKEN で作成した PR は他のワークフローをトリガーしない制約の回避）、PR 作成、および agent-commons リポジトリからの共通設定取得に使用する。

**Fine-grained token（推奨）:**

1. GitHub > Settings > Developer settings > [Personal access tokens > Fine-grained tokens](https://github.com/settings/tokens?type=beta)
2. **Generate new token** をクリック
3. Token name: 任意（例: `shared-workflows-pat`）
4. Repository access: **All repositories** または対象リポジトリ + `becky3/agent-commons` を個別選択
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

### Variables の設定（任意）

| Variable | デフォルト | 説明 |
|----------|-----------|------|
| `AUTO_MERGE_ENABLED` | `false` | `true` で自動マージ有効化（それ以外はドライラン） |
| `COPILOT_REVIEW_TIMEOUT` | `900` | Copilot レビュー待機の最大秒数 |

### 個別セットアップ

統合スクリプトを使わず、手動で個別にセットアップする場合:

- **ラベルのみ作成**: `bash scripts/setup-labels.sh owner/repo`
- **caller workflow**: `examples/caller-workflows/` から `.github/workflows/` にコピーし、`<YOUR_USERNAME>` を置換
- **プロンプト**: `examples/prompts/auto-fix-check-pr.md` を `.github/prompts/` に配置
- **GA 環境ルール**: `examples/claude/CLAUDE-auto-progress.md` を `.claude/` に配置

## バージョニング

呼び出し側は `@main` で参照する:

```yaml
uses: becky3/shared-workflows/.github/workflows/<workflow>.yml@main
```
