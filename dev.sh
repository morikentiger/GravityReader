#!/bin/bash
set -e

APP_NAME="GravityReader"
APP_DIR="$APP_NAME.app"

echo "🔨 Building (debug)..."
swift build 2>&1

echo "📦 Updating .app..."
cp "$(swift build --show-bin-path)/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_DIR"

echo "✅ Done! アプリを再起動してください"
echo "   open $APP_DIR"
