#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/dist}/段落翻译.app"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_DIR/ParagraphTranslator" "$APP_DIR/Contents/MacOS/ParagraphTranslator"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Remove debugging records containing local source/object paths before signing.
xcrun strip -S "$APP_DIR/Contents/MacOS/ParagraphTranslator"
codesign --force --sign - "$APP_DIR"
printf '已生成：%s\n' "$APP_DIR"
