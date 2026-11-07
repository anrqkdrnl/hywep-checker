#!/bin/bash
# build_bundle.sh <앱 이름> <실행파일명> <번들ID> <앱 소스> <SF Symbol> <색1> <색2> <출력 폴더> [버전]
set -e
NAME="$1"; EXE="$2"; BID="$3"; SRC="$4"; SYM="$5"; C1="$6"; C2="$7"; OUT="$8"; VER="${9:-2.0.0}"
cd "$(dirname "$0")"
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP="$OUT/$NAME.app"; TMP="$OUT/.tmp-$EXE"
rm -rf "$APP" "$TMP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"
for arch in arm64 x86_64; do  # Apple Silicon + Intel 둘 다
  xcrun swiftc -swift-version 5 -parse-as-library -O -target $arch-apple-macos14.0 \
    Shared.swift "$SRC" -o "$TMP/$EXE-$arch"
done
lipo -create "$TMP/$EXE-arm64" "$TMP/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
IS="$TMP/AppIcon.iconset"; mkdir -p "$IS"
xcrun swift make_icon.swift "$SYM" "$C1" "$C2" "$TMP/icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$IS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
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
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>비공식 개인 도구 · 한양대학교와 무관</string>
</dict></plist>
PL
rm -rf "$TMP"
xattr -cr "$APP"
codesign --force --sign - "$APP" 2>/dev/null
echo "$APP"
