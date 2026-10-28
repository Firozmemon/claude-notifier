#!/bin/bash
# Builds a shareable, universal (Apple Silicon + Intel) ClaudeNotifier.dmg into ./dist
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-1.0}"
BUILD="$DIR/build"
APP="$BUILD/stage/Claude Notifier.app"
DMG="$DIR/dist/ClaudeNotifier-$VERSION.dmg"
quiet() { "$@" 2>&1 | grep -v '^objc\[' || true; }

rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIR/dist"

for arch in arm64 x86_64; do
  quiet swiftc -O -target "$arch-apple-macos13.0" -o "$BUILD/ClaudeNotifier-$arch" "$DIR/ClaudeNotifier.swift"
  test -f "$BUILD/ClaudeNotifier-$arch"
done
lipo -create -output "$APP/Contents/MacOS/ClaudeNotifier" "$BUILD"/ClaudeNotifier-{arm64,x86_64}

quiet swift "$DIR/make-icon.swift" "$BUILD/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$BUILD/AppIcon.iconset"
cp "$DIR/hook.py" "$APP/Contents/Resources/hook.py"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.firozmemon.claude-notifier</string>
  <key>CFBundleName</key><string>Claude Notifier</string>
  <key>CFBundleDisplayName</key><string>Claude Notifier</string>
  <key>CFBundleExecutable</key><string>ClaudeNotifier</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# A stable identity keeps the Accessibility grant across rebuilds (ad-hoc changes it every build).
IDENTITY="Claude Notifier Local"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing" || true

ln -s /Applications "$BUILD/stage/Applications"
cat > "$BUILD/stage/READ ME FIRST.txt" <<'EOF'
Claude Notifier: a floating panel and menu-bar badge showing every local Claude Code
session (Working / Done / Needs input), whether it runs in Android Studio,
Terminal, iTerm, VS Code or any other terminal.

INSTALL
1. Drag "Claude Notifier" onto the Applications folder.
2. Open it from Applications. macOS will block it the first time because it is
   not from the App Store / not notarized:
     System Settings > Privacy & Security > scroll down > "Open Anyway"
   (or in Terminal:  xattr -dr com.apple.quarantine "/Applications/Claude Notifier.app")
3. Click "Set Up" when asked. That adds status hooks to ~/.claude/settings.json
   (a backup is saved as settings.json.bak-notifier) and starts it at login.
4. Restart any Claude sessions that are already running.

USE
- Click a row to jump to that session: Android Studio / JetBrains IDEs go to the exact
  project window; other terminal apps are brought to the front. Right-click dismisses it.
- The first click asks for Accessibility permission (needed for the exact-window jump).
- The menu-bar item (✳︎) has options for the panel, sound, banners, login start and uninstall.

REQUIRES: macOS 13+, python3 (comes with the Xcode Command Line Tools).
EOF

rm -f "$DMG"
hdiutil create -volname "Claude Notifier" -srcfolder "$BUILD/stage" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
