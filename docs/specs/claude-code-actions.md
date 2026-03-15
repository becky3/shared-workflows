# Claude Code Actions

## 概要

GitHub PR や Issue で `@claude` メンションすることで Claude Code を呼び出し、コードレビュー・実装・質問応答を自動化するワークフロー。

本仕様はメンショントリガーによる対話型の Claude Code 呼び出しを対象とする。ラベルトリガーによる自動実装（`auto-implement`）は自動進行管理ワークフローの範囲。

## 背景

- PR や Issue 上で直接 AI に作業を依頼できると、開発サイクルが短縮される
- GitHub Actions との統合により、手動でのツール切り替えなしに AI 支援を受けられる

## 制約

### セキュリティガード

| ガード | 内容 |
| --- | --- |
| ユーザー制限 | 許可ユーザーのみ実行可能 |
| イベントフィルタリング | 対象イベントのコメントまたは本文に `@claude` メンションを含む場合のみ実行 |
| トークン保護 | シークレット経由で参照（ハードコードしない） |
| ターン制限 | 無限ループ防止のためターン数を制限 |

### 認証方式

OAuth 認証を使用する。

前提条件:

- GitHub Actions から Claude Code 用の OAuth アクセストークンを参照できること
- リポジトリシークレット `CLAUDE_CODE_OAUTH_TOKEN`: Claude GitHub App により発行された OAuth トークンを格納する

## トリガー条件

以下の GitHub イベントで `@claude` メンションが含まれる場合に発火する:

| イベント | 対象 |
| --- | --- |
| `issue_comment` | Issue / PR へのコメント |
| `pull_request_review_comment` | PR レビューコメント |
| `issues` | Issue 作成・アサイン |
| `pull_request_review` | PR レビュー投稿 |

## 処理フロー

```mermaid
flowchart TD
    A[イベント発火] --> B{セキュリティチェック}
    B -->|NG| C[スキップ]
    B -->|OK| D[agent-commons マージ<br/>共通 .claude/ 設定取得]
    D --> E[Claude Code 起動]
    E --> F[コンテキスト取得<br/>Issue/PR 情報]
    F --> G[タスク実行]
    G --> H[結果をコメント投稿<br/>必要に応じてコミット]
```

1. **セキュリティチェック**: ユーザー制限・メンション有無を検証し、条件を満たさない場合はスキップ
2. **agent-commons マージ**: agent-commons リポジトリから共通の `.claude/` 設定（エージェント・スキル・ルール等）を取得し、プロジェクトの `.claude/` にマージする。プロジェクト固有のファイルは上書きしない（no-clobber）
3. **Claude Code 起動**: OAuth トークンで認証し、ターン制限付きで起動
4. **コンテキスト取得**: 対象の Issue / PR の情報を取得
5. **タスク実行**: メンション内容に基づきコードレビュー・実装・質問応答を実行
6. **結果出力**: Issue / PR へのコメントとして回答を投稿。必要に応じてコード変更をコミット・プッシュ

## 出力

### 成功時

- Issue / PR へのコメントとして回答を投稿
- 実装依頼の場合はコード変更のコミット・プッシュ

### 失敗・スキップ時

- セキュリティチェック不合格: 何も出力せずスキップ
- Claude Code 実行エラー: GitHub Actions のログに記録

## ワークフロー構成

Reusable Workflow として `shared-workflows` リポジトリに集約されている。

| 層 | ファイル | 役割 |
|---|---|---|
| Caller | `.github/workflows/claude.yml`（caller リポ） | トリガーイベント定義 + パラメータ指定 |
| Reusable | `shared-workflows/.github/workflows/claude.yml` | Claude Code Action の実行ロジック |

### パラメータ

Caller から Reusable Workflow に渡す入力パラメータ:

| パラメータ | 必須 | 概要 |
|---|:---:|---|
| `allowed_user` | Yes | トリガーを許可する GitHub ユーザー名 |
| `model` | No | Claude モデル名 |
| `max_turns` | No | 最大ターン数 |
| `bot_name` | No | Bot 表示名 |
| `bot_id` | No | Bot ID |
| `auto_progress_prompt` | No | GA 環境用のカスタム指示。`prompt` input 経由で `<custom_instructions>` として注入（空文字列で省略）。`.claude/CLAUDE-auto-progress.md` 配置方式との併用可 |

### シークレット

`secrets: inherit` で呼び出し側から引き継ぐ。Reusable Workflow 側で以下のシークレットが必須:

| シークレット | 概要 |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code Action の OAuth トークン |
| `REPO_OWNER_PAT` | ワークフロー連鎖・PR 作成用の個人アクセストークン。agent-commons リポジトリへの読み取りアクセスも必要 |

## 関連ドキュメント

- [auto-progress](auto-progress.md) — 自動進行管理（`auto-implement` ラベルトリガーを含む）
