# AppMover Native

AppMover Native は、`/Applications` にあるサードパーティ製アプリを外付けドライブへ移動し、必要に応じてシステムボリュームへ戻せるようにする、ネイティブ macOS ユーティリティのプロトタイプです。

現在の実装は SwiftUI と AppKit ベースです。Electron や常駐ヘルパーに依存しない、実用的なデスクトップツールを目指しています。

言語:

- [中文](./README.zh-CN.md)
- [English](./README.en.md)
- [日本語](./README.ja.md)

## 現在の機能

- `/Applications` 内のサードパーティ製 `.app` をスキャン
- `/Volumes` 配下の利用可能な外付けボリュームを検出し、保存先ディレクトリを手動指定可能
- アプリを外付けドライブへ移動し、元のパスにはシンボリックリンクを維持
- すでに外付けドライブ上にあるアプリを検出。システム側リンク未作成のものも対象
- システムボリュームへの復元
- 外付けドライブ上の単独アプリに対するシステム側シンボリックリンク作成
- リスト表示とグリッド表示をサポート
- ツール内から直接アプリを起動可能
- 移動または復元の前に、対象アプリの実行中プロセスの終了を試行
- 実行可能な `.app` を生成するネイティブなパッケージングスクリプトを提供

## 向いている用途

- 内蔵ストレージの空き容量が少なく、大きなサードパーティ製アプリを外付け SSD に移したい
- `/Applications/AppName.app` という入口を維持し、ランチャーやスクリプト、Spotlight を壊したくない
- すでに手動で外付けドライブへ移したアプリに、システム側の統一された入口を追加したい

## 向いていない用途

- Apple によりプリインストールされたアプリ
- 固定インストール先、システム拡張、常駐エージェント、複雑なアップデータに強く依存するアプリ
- 署名やインストール場所に厳しい前提を持つ一部の Mac App Store アプリ
- ExFAT、FAT、NTFS など、macOS の `.app` バンドル保存に長期的には不向きな外付けボリューム

## 開発環境

- macOS 14 以上
- Xcode 16 以上、または Swift 6.2 のコマンドラインツール

## ローカル実行

```bash
swift run
```

## `.app` としてパッケージ

```bash
chmod +x scripts/package-app.sh
./scripts/package-app.sh
```

生成先:

```text
dist/AppMoverNative.app
```

## プロジェクト構成

```text
Sources/AppMoverNative/
  AppMoverNativeApp.swift
  AppMoverViewModel.swift
  ContentView.swift
  MigrationService.swift
  Models.swift

Packaging/
  Info.plist
  AppIcon-1024.png

scripts/
  package-app.sh
  generate_app_icon.py
```

## 設計メモ

- これはクロスプラットフォームのシェルではなく、ネイティブ macOS プロジェクトです
- 移動の実体は「外付けドライブへコピーし、元の場所をシンボリックリンクに置き換える」方式です
- `/Applications` への書き込みやアプリの置き換えには、引き続きシステム権限が必要です
- 使用中ファイルの問題を減らすため、移動や復元の前に対象アプリの終了を試みます
- 現時点では、見た目よりも安定性と制御性を優先しています

## 既知の制限

- 一部のアップデータはアプリを再びシステムボリュームへ書き戻す可能性があります
- 外付けドライブを取り外すと、シンボリックリンク依存のアプリは起動できません
- ドラッグ＆ドロップによる移動操作はまだ調整中です
- 自動アップデート機能はまだありません

## License

このプロジェクトは [WTFPL](./LICENSE) で公開されています。
