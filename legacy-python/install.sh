#!/bin/bash
# HY-WEP 새 공고 체커 설치 — 실행: ./install.sh
#   다시 실행해도 안전 (기존 기준 목록 유지)
#   ./install.sh --reset-login   포털 아이디/비번 다시 저장
#   ./install.sh --no-app        맥 앱 빌드 생략
set -e
cd "$(dirname "$0")"
D="$HOME/.hywep_check"
LABEL="com.seongsu.hywepcheck"
P="$HOME/Library/LaunchAgents/$LABEL.plist"
RESET=0; NOAPP=0
for a in "$@"; do
  [ "$a" = "--reset-login" ] && RESET=1
  [ "$a" = "--no-app" ] && NOAPP=1
done
mkdir -p "$D" "$HOME/Library/LaunchAgents"

echo "▶ 1/5 스크립트 설치 → $D"
cp hywep_check.py "$D/"
cat > "$D/run.sh" <<SH
#!/bin/bash
exec "$D/venv/bin/python" "$D/hywep_check.py" "\$@"
SH
chmod +x "$D/run.sh" "$D/hywep_check.py"

echo "▶ 2/5 Playwright + Chromium 설치 (처음엔 1~2분)"
PY=/usr/bin/python3; [ -x "$PY" ] || PY="$(command -v python3)"
[ -x "$D/venv/bin/python" ] || "$PY" -m venv "$D/venv"
"$D/venv/bin/python" -m pip install -q --upgrade pip playwright
"$D/venv/bin/python" -m playwright install chromium

echo "▶ 3/5 포털 로그인 정보 → macOS 키체인"
if [ $RESET = 1 ] || ! security find-generic-password -a "$USER" -s hyu-portal-pw >/dev/null 2>&1; then
  read -r -p "  한양 포털 아이디: " HYID
  security add-generic-password -U -a "$USER" -s hyu-portal-id -w "$HYID"
  read -r -s -p "  포털 비밀번호 (화면에 안 보임): " HYPW; echo
  security add-generic-password -U -a "$USER" -s hyu-portal-pw -w "$HYPW"
  unset HYPW
else
  echo "  이미 저장돼 있음 (바꾸려면 --reset-login 또는 앱 설정)"
fi

echo "▶ 4/5 첫 실행(기준 목록 저장) + 자동 실행 등록"
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$D/venv/bin/python</string><string>$D/hywep_check.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardOutPath</key><string>$D/launchd.out</string>
  <key>StandardErrorPath</key><string>$D/launchd.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
"$D/run.sh" --force --no-popup || echo "  ⚠️ 첫 실행 실패 — ~/.hywep_check/error.log 확인"
launchctl bootstrap "gui/$(id -u)" "$P"

echo "▶ 5/5 (맥 앱은 v2부터 저장소 루트 README 참고 — 이 레거시 버전에는 포함 안 함)"

echo
echo "✅ 완료. 매일 05시 이후 맥을 처음 깨울 때 1번 확인해서 새 공고가 있으면 팝업."
echo "   앱: /Applications/HY-WEP 체커.app   |   터미널: ~/.hywep_check/run.sh --force"
