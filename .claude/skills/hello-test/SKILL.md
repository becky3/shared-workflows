---
name: hello-test
description: GA環境でのSkill動作検証用。指定されたメッセージをエコーバックする。
user-invocable: true
---

## タスク

動作検証用のスキル。以下を実行すること:

1. 「hello-test スキルが正常に呼び出されました」と出力する
2. `$ARGUMENTS` が指定されている場合、その内容をエコーバックする
3. 現在の日時を `date` コマンドで取得して表示する

## 引数

`$ARGUMENTS`: 任意のメッセージ（省略可）
