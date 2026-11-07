#!/bin/bash
# 앱 빌드: ./build.sh            → build/HY-WEP 체커.app
#         ./build.sh --install  → 빌드 후 /Applications 에 설치 (쓰기 권한 없으면 ~/Applications)
#         ./build.sh --zip      → 배포용 zip (build/HywepChecker.zip)
# 필요: Xcode (Command Line Tools만으로는 SwiftUI 매크로가 없어 빌드 실패)
set -e
cd "$(dirname "$0")"
VER="$(cat VERSION)"
app/build_bundle.sh "HY-WEP 체커" HywepChecker io.github.anrqkdrnl.hywepchecker HywepApp.swift briefcase.fill 1FB89A 0B7A62 "$PWD/build" "$VER" >/dev/null
APP="build/HY-WEP 체커.app"
echo "빌드 완료: $APP (v$VER)"
for a in "$@"; do
  if [ "$a" = "--install" ]; then
    DEST=/Applications; [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
    pkill -x HywepChecker 2>/dev/null || true
    rm -rf "$DEST/HY-WEP 체커.app"; cp -R "$APP" "$DEST/"
    echo "설치 완료: $DEST/HY-WEP 체커.app"
  fi
  if [ "$a" = "--zip" ]; then
    rm -f build/HywepChecker.zip
    ditto -c -k --keepParent "$APP" build/HywepChecker.zip
    echo "zip: build/HywepChecker.zip"
  fi
done
