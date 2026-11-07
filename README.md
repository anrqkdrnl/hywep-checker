# HY-WEP 새 공고 체커 (hywep-checker)

한양대 현장실습 포털 **HY-WEP**(hywep.hanyang.ac.kr)에서 **접수중인 현장실습 공고를 매일 자동으로 모으고, 새로 올라온 공고를 알려주는** macOS 도구.

- 매일 아침 맥을 처음 깨울 때 한 번 확인해. **새 공고가 있으면 팝업**으로, 없으면 알림 센터로 조용히 알려줘.
- **맥 앱(HY-WEP 체커.app)**에서 전체 공고를 표로 보면서 검색, 정렬, 필터를 할 수 있어. 터미널은 안 써도 돼.
- **읽기 전용**이야. 공고 목록 조회 요청만 보내고, 신청이나 취소처럼 상태를 바꾸는 요청은 절대 보내지 않아.
- 포털 아이디와 비밀번호는 **macOS 키체인에만** 저장돼.

---

## 목차

1. [미리보기](#미리보기)
2. [요구 사항](#요구-사항)
3. [설치](#설치)
4. [사용법 — 맥 앱](#사용법--맥-앱)
5. [사용법 — 자동 실행 / 팝업](#사용법--자동-실행--팝업)
6. [사용법 — 터미널](#사용법--터미널)
7. [동작 원리](#동작-원리)
8. [파일 위치](#파일-위치)
9. [문제 해결](#문제-해결)
10. [업데이트 / 삭제](#업데이트--삭제)
11. [프로젝트 구조](#프로젝트-구조)

---

## 미리보기

```
HY-WEP 접수중 공고  [새 공고 3]        ☐ 새 공고만  ☑ 마감 지난 것 숨기기  [⟳ 지금 확인] [HY-WEP 열기] [⚙]
총 194건 · 표시 185건 · 마지막 확인 11/7(토) 13:19 (1초 전)                   🔍 기관·부서·전공·지역 검색
──────────────────────────────────────────────────────────────────────────────────────────
발견  기관                부서            모집마감                 실습기간               지원금        ...
NEW   ○○연구원            모빌리티연구실   D-2 · 11/9(월) 16시까지    2027-01-05~2027-02-27  월/1,800,000  ...
기준  환경부 국립생물자원관  생물다양성총괄과  D-10 · 11/17(화) 16시까지  2027-01-05~2027-02-04  월/1,677,230  ...
```

- **발견** 열:
  - `NEW`: 오늘 처음 발견된 공고
  - 날짜: 그 날짜에 처음 발견된 공고
  - `기준`: 설치할 때 이미 있던 공고
- 마감까지 **2일 이내**인 공고는 빨간색으로 표시돼.

---

## 요구 사항

| 항목 | 내용 |
|---|---|
| macOS | 14 (Sonoma) 이상 |
| Python | 3.9 이상 (`/usr/bin/python3` 등) |
| Xcode | **맥 앱을 빌드할 때만** 필요해. App Store에서 설치하고 한 번 실행해 둬. Command Line Tools만으로는 SwiftUI 매크로가 없어서 빌드가 실패해. |
| 계정 | 한양대 포털 아이디/비밀번호 (HY-WEP 학생 로그인에 쓰는 것) |

---

## 설치

```bash
git clone https://github.com/anrqkdrnl/hywep-checker.git
cd hywep-checker
./install.sh
```

설치 스크립트는 아래 다섯 단계를 순서대로 진행해. 다시 실행해도 안전하고, 기존 기준 목록(`seen.json`)은 그대로 남아.

1. **스크립트 복사**: `hywep_check.py`를 `~/.hywep_check/`에 복사하고 `run.sh`를 만들어.
2. **Playwright + Chromium 설치**: `~/.hywep_check/venv` 가상환경을 만들어. 처음에는 1~2분 걸려.
3. **포털 아이디/비밀번호 입력**: 키체인 `hyu-portal-id` / `hyu-portal-pw`에 저장해.
4. **첫 실행**: 지금 접수중인 공고 전체를 **기준 목록**으로 저장하고, 자동 실행(`com.seongsu.hywepcheck`)을 등록해.
5. **맥 앱 빌드**: `/Applications/HY-WEP 체커.app`에 설치해.

옵션:

```bash
./install.sh --reset-login   # 포털 아이디/비번 다시 입력
./install.sh --no-app        # 맥 앱 없이 스크립트 + 자동 실행만
./build_app.sh               # 맥 앱만 다시 빌드
```

### 처음 앱을 열 때

직접 빌드한 앱이라 **"확인되지 않은 개발자"** 경고가 뜰 수 있어. 그럴 땐 Finder에서 앱을 **우클릭 → 열기**를 한 번만 해 줘.

---

## 사용법 — 맥 앱

Spotlight(⌘Space)에서 `HY-WEP 체커`를 검색해서 열어.

| 동작 | 방법 |
|---|---|
| 지금 다시 확인 | **지금 확인** 버튼 또는 **⌘R** (10~20초) |
| 검색 | 오른쪽 위 검색창. 기관, 부서, 모집전공, 소재지, 분류, 학기를 한꺼번에 검색해 (예: `자동차`, `로봇`, `판교`) |
| 새 공고만 보기 | **새 공고만** 체크 |
| 마감 지난 공고 | 기본으로 숨겨져 있어. **마감 지난 것 숨기기**를 해제하면 보여 |
| 정렬 | 열 제목 클릭 (발견, 기관, 모집마감 등). 기본은 최신 등록순이야 |
| 기관 홈페이지 | 행 **더블클릭**. 홈페이지가 없는 공고는 HY-WEP 목록이 열리고 기관명이 복사돼 |
| 기타 | 행 **우클릭**: 홈페이지 열기 / HY-WEP에서 찾기 / 기관명 복사 |
| HY-WEP 사이트 | **HY-WEP 열기** 버튼. 신청은 사이트에서 직접 해 |
| 긴 텍스트 | 모집전공이나 기관명 칸 위에 마우스를 올리면 전체 내용이 보여 |

### 설정 (⚙ 또는 ⌘,)

- **한양 포털 계정**: 아이디와 비밀번호를 바꿔. 비밀번호는 저장 후 화면에 다시 불러오지 않아.
- **자동 확인 켜기/끄기**: launchd 자동 실행을 등록하거나 해제해.
- **기준 목록 초기화**: 지금까지 본 공고 기록을 지우고, 현재 공고로 기준 목록을 다시 만들어.
- **오류 로그 / HTML 리포트 / 데이터 폴더 열기**

---

## 사용법 — 자동 실행 / 팝업

- launchd가 10분마다 깨우지만, 실제 확인은 **하루 1번**만 해 (05시 이후 처음 깨어났을 때).
- **새 공고가 있으면** 팝업에 최대 10건까지 보여줘 (🔥는 마감 2일 이내). **자세히**를 누르면 앱이 열려.
- **새 공고가 없으면** 알림 센터에 `새 공고 없음 (접수중 N건)`만 띄워.
- 실패하면 error.log에 기록해. 로그인 실패는 바로 팝업으로 알려주고, 그 밖의 오류는 3번째 실패 때 팝업으로 알려줘 (하루 1번만).

---

## 사용법 — 터미널

```bash
~/.hywep_check/run.sh --force              # 지금 확인 + 팝업
~/.hywep_check/run.sh --force --no-popup   # 팝업 없이 결과만 갱신 (앱이 이걸 써)
~/.hywep_check/run.sh --reset              # 기준 목록 초기화 후 실행
~/.hywep_check/run.sh --open               # 결과 보기 (앱, 없으면 HTML 리포트)
```

---

## 동작 원리

```
launchd (10분마다)    ──┐
HY-WEP 체커.app (버튼) ─┴─▶ hywep_check.py (Playwright, headless Chromium)
                             1. hywep.hanyang.ac.kr → 학생 로그인 (한양 OAuth, 키체인 아이디/비번)
                             2. 진행중인 학기 탭 전부 × '접수중' 공고 목록 페이지 전부를 POST로 조회 (읽기만)
                             3. seen.json(지금까지 본 공고 ID)과 비교 → 새 공고 판별
                             ▼
                   latest.json (앱) · latest.html (리포트) · seen.json · 팝업/알림
```

- 처음 실행할 때 있던 공고는 모두 `기준`으로 저장해. 그다음부터 처음 보는 공고 ID가 나오면 그날 날짜로 기록하고 NEW로 표시해.
- 공고가 0건으로 나오면 페이지 구조가 바뀐 것으로 보고 오류로 처리해. 이때 기준 목록은 그대로 둬.

---

## 파일 위치

| 경로 | 내용 |
|---|---|
| `~/.hywep_check/hywep_check.py`, `run.sh` | 설치된 스크립트 |
| `~/.hywep_check/venv/` | Python 가상환경 (Playwright) |
| `~/.hywep_check/latest.json` | 최근 결과 (앱이 읽어) |
| `~/.hywep_check/latest.html` | 최근 결과 HTML 리포트 (검색/필터 가능) |
| `~/.hywep_check/seen.json` | 지금까지 본 공고 ID → 처음 발견한 날짜 |
| `~/.hywep_check/last_run`, `last_fail` | 하루 1번 가드, 실패 횟수 |
| `~/.hywep_check/error.log` | 오류 로그 |
| `~/Library/LaunchAgents/com.seongsu.hywepcheck.plist` | 자동 실행 설정 |
| 키체인 `hyu-portal-id` / `hyu-portal-pw` | 포털 아이디 / 비밀번호 |

---

## 문제 해결

**"로그인 후에도 공고 목록이 안 보임"**
아이디나 비밀번호가 틀렸거나, 포털 비밀번호를 바꿨거나, 포털이 점검 중일 수 있어. 앱 설정에서 계정을 다시 저장한 다음 **지금 확인**을 눌러 봐.

**"접수중 공고 0건 — 페이지 구조가 바뀌었을 수 있음"**
HY-WEP 사이트가 개편됐을 가능성이 커. `hywep_check.py`의 `COLLECT_JS` 부분을 수정해야 해.

**아침에 팝업이 안 떠**
- 앱 설정에서 **자동 확인**이 켜져 있는지 봐 (`launchctl list | grep hywepcheck`).
- 새 공고가 없는 날은 팝업 대신 알림 센터에만 떠. 알림이 꺼져 있으면 안 보일 수 있어.
- `~/.hywep_check/error.log`, `launchd.err`를 확인해.

**앱 빌드 오류 (`SwiftUIMacros.StateMacro` / `detritus not allowed`)**
Xcode를 설치한 뒤 `./build_app.sh`를 다시 실행해. 빌드 스크립트가 Xcode 툴체인 선택과 `xattr -cr`를 알아서 처리해.

---

## 업데이트 / 삭제

업데이트:

```bash
cd hywep-checker && git pull && ./install.sh
```

삭제:

```bash
launchctl bootout gui/$(id -u)/com.seongsu.hywepcheck
rm ~/Library/LaunchAgents/com.seongsu.hywepcheck.plist
rm -rf ~/.hywep_check "/Applications/HY-WEP 체커.app"
security delete-generic-password -a "$USER" -s hyu-portal-id
security delete-generic-password -a "$USER" -s hyu-portal-pw
```

---

## 프로젝트 구조

```
hywep-checker/
├── install.sh          # 전체 설치 (스크립트 · venv · 키체인 · 첫 실행 · launchd · 앱)
├── build_app.sh        # 맥 앱만 빌드해서 /Applications에 설치
├── hywep_check.py      # 본체: 로그인 → 공고 수집 → 새 공고 비교 → 리포트/팝업/latest.json
└── app/
    ├── HywepApp.swift  # SwiftUI 앱 (공고 표, 검색/필터, 설정)
    ├── Shared.swift    # 프로세스 실행, 키체인, launchd, 날짜 포맷, 공용 뷰
    └── make_icon.swift # SF Symbol로 앱 아이콘 생성
```

앱은 Python 스크립트를 `--force --no-popup`으로 실행하고 `latest.json`을 읽어서 보여주기만 해. 그래서 자동 실행과 앱이 항상 같은 데이터를 써.

## 주의

- 개인용 비공식 도구라서 학교와는 관련이 없어. 사이트 구조가 바뀌면 동작하지 않을 수 있어.
- 조회만 해. 신청은 반드시 HY-WEP 사이트에서 직접 해.
