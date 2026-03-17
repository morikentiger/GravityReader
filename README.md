# GravityReader

**GRAVITY.app** の音声ルームで流れるテキストチャットを自動で読み上げるmacOSメニューバーアプリです。
AI パートナー **YUi（ゆい）** が会話の切れ目を検知し、穏やかなコメントを返してくれます。

---

## 機能

| 機能 | 説明 |
|---|---|
| テキスト読み上げ | GRAVITY のタイムラインに流れるテキストメッセージを検出し、日本語 TTS で読み上げ |
| AI パートナー YUi | 会話の切れ目（8秒の沈黙）を検知し、OpenAI API (GPT-4o) で感想・共感コメントを生成して音声で返答 |
| 音声文字起こし | スペースキー長押しでホスト（ルーム主）の音声をリアルタイム文字起こし。YUi の会話コンテキストにも反映 |
| ログウィンドウ | 読み上げたメッセージ、YUi の返答、文字起こし結果をリアルタイム表示 |

## 必要な環境

- **macOS 13.0** (Ventura) 以降
- **Swift 5.9** 以降（Xcode Command Line Tools で可）
- **GRAVITY.app** がインストール・起動済み
- **OpenAI API キー**（YUi 機能を使う場合）

## ビルド・起動

```bash
# リポジトリをクローン
git clone https://github.com/morikentiger/GravityReader.git
cd GravityReader

# ビルド（.app バンドルが生成されます）
bash build.sh

# 起動
open GravityReader.app
```

> Xcode は不要です。Command Line Tools (`xcode-select --install`) のみで動作します。

## 初回セットアップ

### 1. macOS の権限を許可

初回起動時に以下の許可が必要です。
**システム設定 > プライバシーとセキュリティ** から設定してください。

| 権限 | 用途 |
|---|---|
| **アクセシビリティ** | GRAVITY アプリからテキストを取得 |
| **マイク** | ホストの音声を文字起こし |
| **音声認識** | 音声をテキストに変換 |

> ビルドし直すとバイナリが変わるため、権限の再許可が必要になることがあります。

### 2. OpenAI API キーを設定

メニューバーの 📖 アイコン → **🔑 APIキー設定** から OpenAI API キーを入力してください。
キーはローカルの UserDefaults に保存され、外部には送信されません（OpenAI API への通信を除く）。

## 使い方

### 基本操作

1. メニューバーの 📖 アイコンをクリック
2. **▶ 読み上げ開始** を選択
3. GRAVITY のタイムラインに新しいメッセージが来ると自動で読み上げ

### メニュー項目

| メニュー | 説明 |
|---|---|
| ▶ 読み上げ開始 / ⏹ 停止 | 読み上げの開始・停止を切り替え |
| 📋 ログを表示 | ログウィンドウを表示 |
| 🔊 テスト読み上げ | TTS が正常に動作するかテスト |
| 🔑 APIキー設定 | OpenAI API キーを設定 |

### 音声文字起こし（Push-to-Talk）

**スペースキーを長押し**している間、マイクから音声を録音します。
キーを離すと音声認識が完了し、ログに `🎤 ホスト: （文字起こし内容）` と表示されます。

- 他のアプリ（GRAVITY）にフォーカスがあっても動作します
- Cmd+Space / Option+Space などの修飾キー付きは無視されます（IME 切り替えと衝突しません）
- 文字起こし結果は YUi の会話コンテキストにも送られます

### YUi（AI パートナー）

- タイムラインのメッセージとホストの文字起こしを蓄積
- **8秒間**新しいメッセージがなければ「会話の切れ目」と判断
- 溜まった会話をもとに GPT-4o が穏やかなコメントを生成
- コメントは TTS で音声再生され、ログに `🤖 YUi: ...` と表示

## アーキテクチャ

```
GravityReader
├── main.swift                    # エントリポイント
├── AppDelegate.swift             # 各コンポーネントの初期化・接続
├── StatusBarController.swift     # メニューバー UI
├── LogWindowController.swift     # ログウィンドウ（フローティング）
├── GravityCaptureManager.swift   # Accessibility API で GRAVITY からテキスト取得
├── SpeechManager.swift           # AVSpeechSynthesizer によるキュー付き TTS
├── VoiceTranscriptionManager.swift # Push-to-Talk 音声文字起こし
└── YUiManager.swift              # AI パートナー（沈黙検知 + OpenAI API）
```

### 仕組み

- **テキスト取得**: macOS Accessibility API (`AXUIElement`) で GRAVITY のウィンドウを走査し、`AXGenericElement` / `AXStaticText` のテキストを取得
- **新着検知**: 初回ポーリングでベースラインを取得し、以降は差分のみ読み上げ（2秒間隔）
- **TTS**: `AVSpeechSynthesizer` で日本語音声を再生（キュー方式で順番に読み上げ）
- **音声認識**: `SFSpeechRecognizer` + `AVAudioEngine` でリアルタイム文字起こし
- **YUi**: 会話バッファに蓄積 → 8秒沈黙で `DispatchWorkItem` 発火 → OpenAI Chat Completions API

## ライセンス

MIT License
