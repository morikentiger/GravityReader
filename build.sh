#!/bin/bash
set -e

APP_NAME="GravityReader"
BUILD_DIR=".build/release"
APP_DIR="$APP_NAME.app"
BUNDLE_DIR="$APP_DIR/Contents"
GIT_VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0-dev")
GIT_SHORT_VERSION=$(echo "$GIT_VERSION" | sed 's/^v//' | cut -d'-' -f1)

echo "🔨 Building $APP_NAME..."
swift build -c release 2>&1

echo "📦 Creating .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$BUNDLE_DIR/MacOS"
mkdir -p "$BUNDLE_DIR/Resources"

# Copy binary (executable target is GravityReaderMain)
cp "$BUILD_DIR/GravityReaderMain" "$BUNDLE_DIR/MacOS/$APP_NAME"

# Create Info.plist
cat > "$BUNDLE_DIR/Info.plist" << PLIST
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
    <string>${GIT_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${GIT_SHORT_VERSION}</string>
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
</dict>
</plist>
PLIST

echo "📋 Version: $GIT_VERSION ($GIT_SHORT_VERSION)"

# Ad-hoc code sign (required for macOS accessibility permission list)
echo "🔏 Signing..."
codesign --force --sign - "$APP_DIR"

echo "✅ Done!"
echo "   起動: open $APP_DIR"
echo "   一括: bash run.sh （ビルド＋権限付与＋起動）"
