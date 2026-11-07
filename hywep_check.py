#!/usr/bin/env python3
"""HY-WEP 현장실습 새 공고 체커 (읽기 전용).

- 하루 1회(05시 이후 첫 실행) 포털 로그인 → '접수중' 공고 전체 수집 → 어제까지 본 공고와 비교
- 새 공고가 있으면 팝업, 전체 목록은 최신 등록순 HTML 리포트로 저장
- 아이디/비번은 macOS 키체인(hyu-portal-id / hyu-portal-pw)에서만 읽음
- 신청·취소 등 상태를 바꾸는 요청은 절대 보내지 않음 (목록 조회 POST만)

사용법:
  hywep_check.py            # launchd용 (하루 1회 가드)
  hywep_check.py --force    # 지금 바로 실행
  hywep_check.py --reset    # 기준 목록 초기화 후 실행
  hywep_check.py --open     # 마지막 리포트 열기
  --no-popup                # 앱에서 실행: 팝업 없이 결과만 저장, 실패 시 exit 1
"""
import datetime
import html
import json
import os
import re
import subprocess
import sys
import traceback
from pathlib import Path

BASE = Path.home() / ".hywep_check"
SEEN = BASE / "seen.json"
LAST_RUN = BASE / "last_run"
LAST_FAIL = BASE / "last_fail"
REPORT = BASE / "latest.html"
JSON_OUT = BASE / "latest.json"  # HY-WEP 체커.app이 읽는 결과
APP_NAME = "HY-WEP 체커"
ERRLOG = BASE / "error.log"

AUTH_URL = ("https://api.hanyang.ac.kr/oauth/authorize?client_id=45a2976f7cc1de834d0492c33b979c"
            "&response_type=code&redirect_uri=https://hywep.hanyang.ac.kr/login.do&scope=10,35")
LIST_URL = "https://hywep.hanyang.ac.kr/compjoinsearch/list.do"
INDEX_URL = "https://hywep.hanyang.ac.kr/index.do"
KST = datetime.timezone(datetime.timedelta(hours=9))
WD = "월화수목금토일"
STATUS_OPEN = "1047"  # 진행상태: 접수중

# 페이지 안에서 실행: 진행중 학기 탭 전부 × 접수중 공고 전 페이지 수집 (조회만)
COLLECT_JS = r"""
async (statusComp) => {
  const clean = s => (s || '').replace(/\s+/g, ' ').trim();
  const scheds = [...document.querySelectorAll('li[onclick^="schedule("]')]
    .map(li => ({id: li.getAttribute('onclick').match(/\d+/)[0], name: clean(li.textContent)}));
  const rows = [];
  for (const s of scheds) {
    for (let pg = 0; pg < 60; pg++) {
      const body = new URLSearchParams({schedule: s.id, comp_code: '', pg: String(pg), status: '1137',
        year: '', term_div: '', status_comp: statusComp, intern_div: '', major_nm: '', comp_name: '', dept: ''});
      const r = await fetch('/compjoinsearch/list.do', {method: 'POST', body, credentials: 'include'});
      if (!r.ok) throw new Error('list.do HTTP ' + r.status);
      const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
      const trs = [...doc.querySelectorAll('tr')].filter(tr => tr.querySelector('a[href*="goView"]'));
      for (const tr of trs) {
        const td = [...tr.children].map(c => clean(c.textContent));
        const home = (tr.querySelector('a[onclick*="goHomepage"]') || {getAttribute: () => ''})
          .getAttribute('onclick').match(/goHomepage\('([^']*)'/);
        rows.push({jid: tr.querySelector('a[href*="goView"]').getAttribute('href').match(/\d+/)[0],
          sched: s.name, cat: td[1], comp: td[2], dept: td[3], state: td[4], recruit: td[5],
          home: home ? home[1] : '', loc: td[7], deadline: td[8], dtime: td[9], period: td[10],
          pay: td[11], type: td[12], major: td[13], quota: td[14], applied: td[15]});
      }
      if (trs.length < 50) break;
    }
  }
  return {scheds, rows};
}
"""


class LoginError(Exception):
    pass


def now():
    return datetime.datetime.now(KST)


def log_err(msg):
    BASE.mkdir(exist_ok=True)
    with ERRLOG.open("a", encoding="utf-8") as f:
        f.write(f"[{now():%Y-%m-%d %H:%M:%S}] {msg}\n")


def keychain(service):
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-a", os.environ.get("USER", ""),
                        "-s", service, "-w"], capture_output=True, text=True)
    if r.returncode != 0:
        raise LoginError(f"키체인 항목 '{service}' 없음 — 설치 스크립트로 다시 저장해줘")
    return r.stdout.rstrip("\n")


def fetch_postings():
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

    uid, pw = keychain("hyu-portal-id"), keychain("hyu-portal-pw")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            page = browser.new_context(locale="ko-KR").new_page()
            dialogs = []

            def on_dialog(d):
                dialogs.append(d.message)
                d.dismiss()

            page.on("dialog", on_dialog)
            # 사이트의 '학생 → 로그인' 버튼과 동일: userGb=1 쿠키 + OAuth 폼 제출 (topLogin('1'))
            page.goto(INDEX_URL, wait_until="domcontentloaded", timeout=40000)
            page.evaluate("() => { setTimeout(() => topLogin('1'), 0); }")
            page.wait_for_url(lambda u: "api.hanyang.ac.kr" in u or "/login.do" in u or "/main" in u,
                              timeout=40000)
            if "api.hanyang.ac.kr" in page.url:
                page.wait_for_selector("#uid", timeout=20000)
                page.fill("#uid", uid)
                page.fill("#upw", pw)
                page.click("#login_btn")
                try:
                    page.wait_for_url(lambda u: "hywep.hanyang.ac.kr" in u, timeout=40000)
                except PWTimeout:
                    why = dialogs[-1].strip() if dialogs else f"멈춘 페이지: {page.url.split('?')[0]}"
                    raise LoginError(f"포털 로그인 실패 ({why})")
            # login.do(code 교환·세션 생성)가 끝나고 다른 페이지로 넘어갈 때까지 대기
            try:
                page.wait_for_url(lambda u: "hywep.hanyang.ac.kr" in u and "/login.do" not in u, timeout=30000)
            except PWTimeout:
                pass
            page.wait_for_load_state("load", timeout=30000)
            after_login = page.url.split("?")[0]
            page.goto(LIST_URL, wait_until="domcontentloaded", timeout=40000)
            if not page.query_selector('li[onclick^="schedule("]'):
                title = page.title()
                msg = dialogs[-1].strip() if dialogs else ""
                raise LoginError(f"로그인 후에도 공고 목록이 안 보임 (로그인 후 페이지: {after_login}, "
                                 f"목록 페이지: {page.url.split('?')[0]} '{title}' {msg})")
            res = page.evaluate(COLLECT_JS, STATUS_OPEN)
        finally:
            browser.close()
    if not res["rows"]:
        raise RuntimeError("접수중 공고 0건 — 페이지 구조가 바뀌었을 수 있음")
    return res


def short_sched(name):
    m = re.search(r"(\d{4})년도\s*(\S+)\s+(\S+)\s*현장실습", name)
    return f"{m.group(1)} {m.group(2)} {m.group(3)}" if m else name.split("(")[0].strip()


def dday(deadline):
    try:
        d = datetime.date.fromisoformat(deadline[:10])
    except ValueError:
        return None, deadline
    n = (d - now().date()).days
    tag = "D-DAY" if n == 0 else (f"D-{n}" if n > 0 else f"D+{-n}")
    return n, f"{d:%m/%d}({WD[d.weekday()]}) {tag}"


def build_report(rows, seen, today, first_run):
    rows = sorted(rows, key=lambda r: int(r["jid"]), reverse=True)
    n_new = sum(1 for r in rows if seen.get(r["jid"]) == today)
    trs = []
    for r in rows:
        fs = seen.get(r["jid"], "")
        is_new = fs == today and not first_run
        n, dd = dday(r["deadline"])
        urgent = n is not None and 0 <= n <= 2
        found = "기준" if fs == "base" else fs[5:].replace("-", "/")
        e = html.escape
        trs.append(
            f'<tr class="{"new" if is_new else ""}" data-new="{int(is_new)}">'
            f'<td>{"<b class=badge>NEW</b>" if is_new else e(found)}</td>'
            f'<td>{e(short_sched(r["sched"]))}</td><td>{e(r["cat"])}</td>'
            f'<td class=comp>{e(r["comp"])}</td><td>{e(r["dept"])}</td>'
            f'<td class="{"urgent" if urgent else ""}">{e(dd)} {e(r["dtime"])}</td>'
            f'<td>{e(r["period"])}</td><td>{e(r["pay"])}</td><td class=major>{e(r["major"])}</td>'
            f'<td>{e(r["quota"])} / {e(r["applied"])}</td><td>{e(r["loc"])}</td></tr>')
    head = ("기준 목록 저장 완료 — 내일부터 새로 올라온 공고에 NEW 표시" if first_run
            else f"오늘 새 공고 {n_new}건")
    return f"""<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">
<title>HY-WEP 접수중 공고 (최신순)</title>
<style>
body{{font:13px -apple-system,BlinkMacSystemFont,'Apple SD Gothic Neo',sans-serif;margin:20px;color:#222}}
h1{{font-size:18px;margin:0 0 4px}} .sub{{color:#666;margin-bottom:12px}}
.bar{{display:flex;gap:12px;align-items:center;margin-bottom:10px}}
input[type=search]{{padding:6px 8px;width:260px;border:1px solid #ccc;border-radius:6px}}
table{{border-collapse:collapse;width:100%}} th,td{{padding:6px 8px;border-bottom:1px solid #eee;text-align:left;vertical-align:top}}
th{{background:#f6f6f6;position:sticky;top:0}} tr.new{{background:#fff8e1}} .badge{{background:#e65100;color:#fff;padding:1px 6px;border-radius:4px;font-size:11px}}
.urgent{{color:#c62828;font-weight:600}} .comp{{font-weight:600}} .major{{max-width:260px;color:#555}}
@media (prefers-color-scheme:dark){{body{{background:#1e1e1e;color:#ddd}} th{{background:#2a2a2a}} td{{border-color:#333}} tr.new{{background:#3a3020}} .major{{color:#aaa}}}}
</style></head><body>
<h1>HY-WEP 접수중 공고 — 최신 등록순</h1>
<div class="sub">{html.escape(head)} · 접수중 총 {len(rows)}건 · {now():%Y-%m-%d %H:%M} 기준 ·
<a href="{LIST_URL}">HY-WEP 열기</a> (신청은 사이트에서 직접)</div>
<div class="bar"><input type="search" id="q" placeholder="기관·부서·전공 검색 (예: 기계, 자동차, 로봇)">
<label><input type="checkbox" id="onlyNew"> 새 공고만</label></div>
<table><thead><tr><th>발견</th><th>학기</th><th>분류</th><th>기관</th><th>부서</th><th>모집마감</th>
<th>실습기간</th><th>지원금</th><th>모집전공</th><th>모집/지원</th><th>소재지</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table>
<script>
const q=document.getElementById('q'),o=document.getElementById('onlyNew');
function f(){{const s=q.value.trim().toLowerCase();for(const tr of document.querySelectorAll('tbody tr')){{
tr.style.display=((!o.checked||tr.dataset.new==='1')&&(!s||tr.textContent.toLowerCase().includes(s)))?'':'none'}}}}
q.oninput=f;o.onchange=f;
</script></body></html>"""


def write_json(rows, seen, today, first_run):
    out = []
    for r in sorted(rows, key=lambda r: int(r["jid"]), reverse=True):
        fs = seen.get(r["jid"], "")
        out.append(dict(r, found=fs, is_new=(fs == today and not first_run)))
    data = {"checked_at": now().isoformat(), "first_run": first_run, "total": len(rows),
            "new_count": sum(1 for r in out if r["is_new"]), "list_url": LIST_URL, "rows": out}
    tmp = JSON_OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(JSON_OUT)


def open_details():
    if subprocess.run(["/usr/bin/open", "-a", APP_NAME], capture_output=True).returncode != 0:
        subprocess.run(["/usr/bin/open", str(REPORT)])


def osa_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def popup(title, body, offer_open=True):
    buttons = '{"닫기", "자세히"}' if offer_open else '{"확인"}'
    default = '"자세히"' if offer_open else '"확인"'
    script = (f'display dialog {osa_str(body)} with title {osa_str(title)} '
              f'buttons {buttons} default button {default}')
    r = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True)
    if offer_open and "자세히" in r.stdout:
        open_details()


def notify(title, body):
    subprocess.run(["/usr/bin/osascript", "-e",
                    f"display notification {osa_str(body)} with title {osa_str(title)}"])


def should_run(force):
    if force:
        return True
    n = now()
    if n.hour < 5:
        return False
    return not (LAST_RUN.exists() and LAST_RUN.read_text().strip() == n.date().isoformat())


def record_fail(today, msg, is_login):
    """실패는 error.log에. 팝업은 하루 1번만 (로그인 실패는 즉시, 그 외는 3번째 실패 때)."""
    log_err(msg)
    cnt, shown = 0, False
    if LAST_FAIL.exists():
        parts = LAST_FAIL.read_text().split()
        if parts and parts[0] == today:
            cnt, shown = int(parts[1]), parts[2] == "1"
    cnt += 1
    show = not shown and (is_login or cnt >= 3)
    LAST_FAIL.write_text(f"{today} {cnt} {int(shown or show)}")
    if show:
        popup("HY-WEP 체커 오류", f"{msg.splitlines()[0]}\n\n자세한 내용: ~/.hywep_check/error.log\n"
              "수동 실행: ~/.hywep_check/run.sh --force", offer_open=False)


def main():
    args = set(sys.argv[1:])
    BASE.mkdir(exist_ok=True)
    if "--open" in args:
        open_details()
        return
    no_popup = "--no-popup" in args
    force = bool(args & {"--force", "--reset"})
    if not should_run(force):
        return
    today = now().date().isoformat()

    try:
        res = fetch_postings()
    except LoginError as e:
        if no_popup:
            log_err(str(e))
            sys.exit(f"ERROR: {e}")
        record_fail(today, str(e), True)
        return
    except Exception:
        if no_popup:
            log_err(traceback.format_exc())
            sys.exit("ERROR: " + traceback.format_exc().strip().splitlines()[-1])
        record_fail(today, traceback.format_exc().strip().splitlines()[-1] + "\n" + traceback.format_exc(), False)
        return

    seen = {}
    if SEEN.exists() and "--reset" not in args:
        try:
            seen = json.loads(SEEN.read_text(encoding="utf-8"))
        except ValueError:
            log_err("seen.json 손상 → 기준 목록 재생성")
    first_run = not seen
    rows = res["rows"]
    new_rows = []
    for r in rows:
        if r["jid"] not in seen:
            seen[r["jid"]] = "base" if first_run else today
            if not first_run:
                new_rows.append(r)

    SEEN.write_text(json.dumps(seen, ensure_ascii=False), encoding="utf-8")
    REPORT.write_text(build_report(rows, seen, today, first_run), encoding="utf-8")
    write_json(rows, seen, today, first_run)
    LAST_RUN.write_text(today)
    if LAST_FAIL.exists():
        LAST_FAIL.unlink()
    if no_popup:
        return

    if first_run:
        popup("HY-WEP 체커 설정 완료",
              f"지금 접수중인 공고 {len(rows)}건을 기준으로 저장했어.\n"
              "내일부터 새로 올라온 공고만 알려줄게.\n\n'자세히' → 전체 목록(최신 등록순)")
        return
    if not new_rows:
        notify("HY-WEP", f"새 공고 없음 (접수중 {len(rows)}건)")
        return

    new_rows.sort(key=lambda r: int(r["jid"]), reverse=True)
    lines = []
    for r in new_rows[:10]:
        n, dd = dday(r["deadline"])
        fire = "🔥" if n is not None and 0 <= n <= 2 else "•"
        lines.append(f"{fire} {dd} | {r['comp']} · {r['dept']}")
    if len(new_rows) > 10:
        lines.append(f"…외 {len(new_rows) - 10}건")
    popup(f"HY-WEP 새 공고 {len(new_rows)}건", "\n".join(lines))


if __name__ == "__main__":
    main()
