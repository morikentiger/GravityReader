#!/bin/bash
set -e

APP_NAME="GravityReader"
APP_DIR="$APP_NAME.app"

# ────────────────────────────────────────
# 1. ビルド
# ────────────────────────────────────────
echo "🔨 ビルド中..."
bash build.sh

# ────────────────────────────────────────
# 2. 既存プロセスを終了
# ────────────────────────────────────────
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "🔄 既存の $APP_NAME を終了しています..."
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
fi

# ────────────────────────────────────────
# 3. 権限の確認案内
# ────────────────────────────────────────
echo ""
echo "🔑 初回はアクセシビリティ権限の許可が必要です"
echo "   システム設定 > プライバシーとセキュリティ > アクセシビリティ で GravityReader を許可してください"
echo "   （既に許可済みならそのまま Enter を押してください）"
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo "   Enter を押すと起動します..."
read -r

# ────────────────────────────────────────
# 4. アプリ起動
# ────────────────────────────────────────
echo "🚀 $APP_NAME を起動します..."
open "$APP_DIR"
echo "✅ 起動しました！"
