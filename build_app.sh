#!/bin/bash
# HY-WEP 체커.app 빌드 → /Applications (쓰기 권한 없으면 ~/Applications)
set -e
cd "$(dirname "$0")/app"
# SwiftUI 매크로(@State) 플러그인은 Xcode 툴체인에만 있음 (Command Line Tools만으로는 빌드 실패)
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
NAME="HY-WEP 체커"; EXE=HywepChecker; BID=com.seongsu.hywepchecker
OUT=../build; APP="$OUT/$NAME.app"
DEST=/Applications; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "  컴파일 중…"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$(uname -m)-apple-macos14.0" \
  Shared.swift HywepApp.swift -o "$APP/Contents/MacOS/$EXE"

IS="$OUT/$EXE.iconset"; rm -rf "$IS"; mkdir -p "$IS"
xcrun swift make_icon.swift briefcase.fill 1FB89A 0B7A62 "$OUT/$EXE.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/$EXE.png" --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$OUT/$EXE.png" --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$IS" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
xattr -cr "$APP"
codesign --force --sign - "$APP" 2>/dev/null
rm -rf "$DEST/$NAME.app"; cp -R "$APP" "$DEST/"
echo "  → $DEST/$NAME.app"
