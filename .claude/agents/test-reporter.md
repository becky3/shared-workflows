---
name: test-reporter
description: GA環境でのAgent動作検証用。リポジトリの基本情報を収集して報告する。
tools: Read, Glob, Bash
---

## タスク

リポジトリの基本情報を収集し、以下の形式で報告すること:

1. リポジトリルートのファイル一覧（`ls -la` の結果）
2. `.claude/` ディレクトリの構成（`find .claude -type f` の結果）
3. 現在のブランチ名

## 返却形式

収集した情報をまとめて、呼び出し元に返すこと。
