#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

make app
BUILD_DIR="${BUILD_DIR:-/tmp/AIQuotaBar-build}"
APP="$BUILD_DIR/AIQuotaBar.app"
mkdir -p "$BUILD_DIR"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/AIQuotaBar" --version
"$APP/Contents/MacOS/AIQuotaBar" --print-snapshot | tee "$BUILD_DIR/snapshot-test.txt"
rg "AIQuotaBar Snapshot" "$BUILD_DIR/snapshot-test.txt"
