#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Comni.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$ROOT_DIR"
swift build -c release --product ComniApp

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/ComniApp" "$CONTENTS_DIR/MacOS/ComniApp"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/Comni.icns" "$CONTENTS_DIR/Resources/Comni.icns"
cp "$ROOT_DIR/Resources/Comni.png" "$CONTENTS_DIR/Resources/Comni.png"
cp "$ROOT_DIR/Resources/Comni-menubar.png" "$CONTENTS_DIR/Resources/Comni-menubar.png"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
