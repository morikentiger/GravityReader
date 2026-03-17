#!/bin/bash
set -e

APP_NAME="GravityReader"
BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app"
BUNDLE_DIR="$APP_DIR/Contents"

echo "🔨 Building $APP_NAME..."
swift build -c release 2>&1

echo "📦 Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$BUNDLE_DIR/MacOS"
mkdir -p "$BUNDLE_DIR/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/MacOS/$APP_NAME"

# Create Info.plist
cat > "$BUNDLE_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>GravityReader</string>
    <key>CFBundleIdentifier</key>
    <string>com.gravityreader.app</string>
    <key>CFBundleName</key>
    <string>GravityReader</string>
    <key>CFBundleDisplayName</key>
    <string>GravityReader</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>GravityReaderはホストの音声を文字起こしするためにマイクを使用します</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>GravityReaderはホストの音声をテキストに変換するために音声認識を使用します</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>GravityReaderはGravityアプリのテキストを取得するためにアクセシビリティ機能を使用します</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>GravityReaderはGravityアプリの画面からテキストを読み取るために画面収録を使用します</string>
</dict>
</plist>
PLIST

echo "✅ Done! Run: open $APP_DIR"
echo ""
echo "⚠️  初回起動後、以下の許可が必要です:"
echo "   システム設定 > プライバシーとセキュリティ > アクセシビリティ → GravityReader を追加"
echo "   システム設定 > プライバシーとセキュリティ > 画面収録 → GravityReader を追加"
