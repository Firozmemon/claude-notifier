#!/bin/bash
# Builds ClaudeNotifier.app into ~/Applications, registers it to start at login, and launches it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ClaudeNotifier.app"

mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeNotifier" "$DIR/ClaudeNotifier.swift" 2>&1 | grep -v '^objc\[' || true
test -x "$APP/Contents/MacOS/ClaudeNotifier"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.firozmemon.claude-notifier</string>
  <key>CFBundleName</key><string>Claude Notifier</string>
  <key>CFBundleExecutable</key><string>ClaudeNotifier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# A stable identity keeps the Accessibility grant across rebuilds (ad-hoc changes it every build).
IDENTITY="Claude Notifier Local"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing" || true

pkill -x ClaudeNotifier 2>/dev/null || true
sleep 1
open "$APP"
echo "Installed: $APP"
