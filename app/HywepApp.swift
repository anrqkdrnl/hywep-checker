// HY-WEP 체커.app — 한양대 현장실습 포털(HY-WEP) 접수중 공고를 모으고 새 공고를 알려줌.
// 앱 안 브라우저로 로그인해서 조회한다 (읽기 전용: 신청·취소 요청은 보내지 않음).
import AppKit
import SwiftUI
import Combine
import WebKit

let hyHome = "https://hywep.hanyang.ac.kr"
let hyIndexURL = hyHome + "/index.do"
let hyListURL = hyHome + "/compjoinsearch/list.do"
let hyViewURL = hyHome + "/compjoinmanage/view_stu.do"
let hyFiles = AppFiles("HY-WEP 체커")
let hyCreds = Credentials(idService: "hyu-portal-id", pwService: "hyu-portal-pw")
let hyAgent = LaunchAgent(label: "io.github.anrqkdrnl.hywepchecker.auto")
let hyResultFile = "latest.json"
let hySeenFile = "seen.json"

// MARK: - 모델

struct Posting: Codable, Identifiable, Hashable {
    var jid = "", sched = "", cat = "", comp = "", dept = "", state = "", recruit = "", home = "", loc = ""
    var deadline = "", dtime = "", period = "", pay = "", type = "", major = "", quota = "", applied = ""
    var found = ""
    var is_new = false
    var id: String { jid }

    var jidNum: Int { Int(jid) ?? 0 }
    var deadlineDate: Date? { DateUtil.parse(deadline) }
    var daysLeft: Int { deadlineDate.map(DateUtil.dayDiff) ?? 9999 }
    var foundLabel: String {
        if is_new { return "NEW" }
        let f = found == "base" ? HyEngine.baselineDay : found
        return DateUtil.parse(f).map(DateUtil.md) ?? f
    }
    var shortSched: String {
        // "2026년도 겨울학기 단기 현장실습 (…)" → "26 겨울 단기"
        let parts = sched.split(separator: " ")
        guard parts.count >= 3, sched.contains("년도") else { return sched }
        return "\(parts[0].prefix(4).suffix(2)) \(parts[1].replacingOccurrences(of: "학기", with: "")) \(parts[2])"
    }

    enum CodingKeys: String, CodingKey {
        case jid, sched, cat, comp, dept, state, recruit, home, loc, deadline, dtime, period, pay, type, major, quota, applied, found, is_new
    }

    init() {}

    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        jid = s(.jid); sched = s(.sched); cat = s(.cat); comp = s(.comp); dept = s(.dept); state = s(.state)
        recruit = s(.recruit); home = s(.home); loc = s(.loc); deadline = s(.deadline); dtime = s(.dtime)
        period = s(.period); pay = s(.pay); type = s(.type); major = s(.major); quota = s(.quota)
        applied = s(.applied); found = s(.found)
        is_new = (try? c.decodeIfPresent(Bool.self, forKey: .is_new)) ?? false
    }
}

struct HyData: Codable {
    let checked_at: String
    let first_run: Bool
    let total: Int
    let new_count: Int
    let rows: [Posting]
}

// MARK: - 조회 엔진

@MainActor
enum HyEngine {
    /// 마지막 로그인 시각 (세션이 살아 있을 가능성 판단용)
    static var lastLogin: Date?
    static var sessionFresh: Bool { lastLogin.map { Date().timeIntervalSince($0) < 20 * 60 } ?? false }

    /// 사이트의 '학생 → 로그인' 버튼과 같은 흐름: topLogin('1') → 한양 통합 로그인 → 목록 페이지
    static let scheduleTabs = "li[onclick^=\"schedule(\"]"

    static func login(_ web: WebSession, _ uid: String, _ pw: String) async throws {
        // 같은 앱 안에서 이미 로그인돼 있으면 바로 목록 (세션이 살아 있을 때 topLogin 흐름은 다르게 움직임)
        try await web.go(hyListURL)
        if await web.exists(scheduleTabs) { lastLogin = Date(); return }

        try await web.go(hyIndexURL)
        _ = try await web.js("setTimeout(() => topLogin('1'), 0); return true;")
        try await web.until(40, "HY-WEP 로그인 페이지") {
            let u = web.url
            return u.contains("api.hanyang.ac.kr") || (u.contains("hywep.hanyang.ac.kr") && !u.contains("index.do"))
        }
        if web.url.contains("api.hanyang.ac.kr") {
            try await web.until(20, "한양 통합 로그인") { await web.exists("#uid") }
            try await web.submitHanyangLogin(uid, pw)
            try await web.until(40, "HY-WEP 로그인", failOnAlert: true) { web.url.contains("hywep.hanyang.ac.kr") }
        }
        try await web.until(30, "HY-WEP") { !web.webView.isLoading }
        try await web.go(hyListURL)
        guard await web.exists(scheduleTabs) else {
            throw WebError.loginRejected("로그인 후에도 공고 목록이 안 보여 \(web.alerts.last ?? "")")
        }
        lastLogin = Date()
    }

    /// 진행중 학기 탭 전부 × '접수중' 공고 전 페이지 (목록 조회 POST만)
    static func collect(_ web: WebSession) async throws -> [Posting] {
        let json = try await web.js(#"""
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
            return JSON.stringify(rows);
            """#, ["statusComp": "1047"]) as? String ?? "[]"
        var rows = try JSONDecoder().decode([Posting].self, from: Data(json.utf8))
        var seenIDs = Set<String>()
        rows = rows.filter { seenIDs.insert($0.jid).inserted }
        for i in rows.indices where !rows[i].home.isEmpty && !rows[i].home.hasPrefix("http") {
            rows[i].home = "http://" + rows[i].home
        }
        return rows
    }

    static func testLogin(_ uid: String, _ pw: String) async throws {
        let web = WebSession()
        defer { web.close() }
        try await login(web, uid, pw)
    }

    /// 로그인 → 수집 → 지금까지 본 공고(seen.json)와 비교 → 결과 저장
    static func run(reset: Bool = false, progress: (String) -> Void = { _ in }) async throws -> HyData {
        guard let (uid, pw) = await hyCreds.load() else { throw WebError.noCredentials }
        let web = WebSession()
        defer { web.close() }
        progress("HY-WEP 로그인 중…")
        try await login(web, uid, pw)
        progress("접수중 공고 가져오는 중…")
        let rows = try await collect(web)
        guard !rows.isEmpty else { throw WebError.other("접수중 공고가 0건 — 사이트 구조가 바뀌었을 수 있어") }

        var seen = reset ? [:] : (hyFiles.load([String: String].self, hySeenFile) ?? [:])
        let today = DateUtil.today()
        let firstRun = seen.isEmpty
        // 예전 형식("base") → 처음 기준을 잡은 날짜
        for (k, v) in seen where v == "base" { seen[k] = baselineDay }
        for r in rows where seen[r.jid] == nil { seen[r.jid] = today }
        try hyFiles.save(seen, hySeenFile)

        let out = rows.map { r -> Posting in
            var p = r
            p.found = seen[r.jid] ?? ""
            p.is_new = !firstRun && p.found == today
            return p
        }.sorted { $0.jidNum > $1.jidNum }
        let data = HyData(checked_at: DateUtil.iso(Date())!, first_run: firstRun, total: out.count,
                          new_count: out.filter(\.is_new).count, rows: out)
        try hyFiles.save(data, hyResultFile)
        return data
    }

    /// 예전 형식 "base"(처음 기준 목록)의 날짜: 예전 Python 버전 기록 파일을 만든 날, 없으면 오늘
    nonisolated static let baselineDay: String = {
        let p = NSHomeDirectory() + "/.hywep_check/seen.json"
        if let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.creationDate] as? Date { return DateUtil.ymd(d) }
        return DateUtil.today()
    }()

    /// 예전 Python 버전의 기록이 있으면 가져와서 NEW 기준을 이어감
    static func importLegacySeen() {
        guard hyFiles.load([String: String].self, hySeenFile) == nil,
              let d = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.hywep_check/seen.json")),
              let seen = try? JSONDecoder().decode([String: String].self, from: d), !seen.isEmpty else { return }
        try? hyFiles.save(seen, hySeenFile)
    }
}

// MARK: - 공고 상세 창 (앱 안 브라우저, 로그인된 세션으로 view_stu.do 열기)

@MainActor
final class DetailController: ObservableObject {
    let web = WebSession(hidden: false)
    @Published var status: String?
    @Published var failed = false
    @Published var posting: Posting?
    /// 지원하기 결과 안내 (상단 표시)
    @Published var applyNote: String?
    /// 스크린샷 저장 결과 (상단 표시)
    @Published var shotNote: (text: String, file: URL?)?
    private(set) var window: NSWindow?
    private var loadTask: Task<Void, Never>?
    private var closeObserver: NSObjectProtocol?
    /// 창이 닫히면 불림 (DetailWindows가 목록에서 지움)
    var onClose: () -> Void = {}
    /// 북마크 버튼용 (셀프테스트처럼 없으면 버튼을 숨김)
    weak var store: HyStore?

    /// 공고 하나당 창 하나. 여러 창이 동시에 열려 있을 수 있음.
    func open(_ p: Posting, cascadeFrom prev: NSWindow? = nil) {
        posting = p
        if window == nil {
            let w = Windows.make("공고 상세", size: NSSize(width: 980, height: 860), autosave: prev == nil ? "detail" : nil, DetailView(ctl: self))
            if let prev {
                // 이미 열린 창과 겹치지 않게 조금씩 비켜서 띄움
                w.setContentSize(prev.contentLayoutRect.size)
                w.setFrameTopLeftPoint(NSPoint(x: prev.frame.minX, y: prev.frame.maxY))
                w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY)))
            }
            w.tabbingIdentifier = "hywep-detail"
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed() }
            }
            window = w
            window!.title = "\(p.comp) · \(p.dept)"
            Windows.present(window!)
            loadTask = Task { await load(forceLogin: false) }
        } else {
            Windows.present(window!)
        }
    }

    private func closed() {
        loadTask?.cancel()
        web.webView.stopLoading()
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = nil
        window?.contentView = nil
        window = nil
        onClose()
    }

    /// 여러 창이 동시에 열릴 때 로그인을 한 번만 하도록 묶음 (같은 쿠키 저장소를 씀)
    private static var loginInFlight: Task<Void, Error>?

    static func ensureLogin(_ web: WebSession) async throws {
        if let t = loginInFlight { return try await t.value }
        let t = Task { @MainActor in
            guard let (u, pw) = await hyCreds.load() else { throw WebError.noCredentials }
            try await HyEngine.login(web, u, pw)
        }
        loginInFlight = t
        defer { loginInFlight = nil }
        try await t.value
    }

    func reload(forceLogin: Bool) {
        loadTask?.cancel()
        loadTask = Task { await load(forceLogin: forceLogin) }
    }

    private func load(forceLogin: Bool) async {
        guard let p = posting else { return }
        failed = false
        applyNote = nil
        web.interactive = false
        do {
            if forceLogin || !HyEngine.sessionFresh {
                status = "HY-WEP 로그인 중…"
                try await Self.ensureLogin(web)
                if Task.isCancelled { return }
            }
            status = "공고 여는 중…"
            var req = URLRequest(url: URL(string: hyViewURL)!)
            req.httpMethod = "POST"
            req.httpBody = "jid_seq=\(p.jid)".data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(hyListURL, forHTTPHeaderField: "Referer")
            web.clearAlerts()
            try await web.go(req)
            if Task.isCancelled { return }
            // 세션이 끊겨 다른 페이지로 튕겼으면 한 번만 다시 로그인
            if !web.url.contains("view_stu.do") || !web.alerts.isEmpty {
                if !forceLogin { return await load(forceLogin: true) }
                throw WebError.other("공고 페이지를 못 열었어 \(web.alerts.last ?? "")")
            }
            status = nil
        } catch {
            if Task.isCancelled { return }
            failed = true
            status = error.message
        }
    }
}

extension DetailController {
    /// HY-WEP 목록에서 이 공고 줄을 찾아 사이트의 '신청하기'를 대신 눌러준다.
    /// 실제 신청 여부는 사이트가 띄우는 확인 창에서 사용자가 고른다 (confirm은 대화상자로 표시).
    /// dryRun이면 찾기만 하고 누르지 않음 (셀프테스트용).
    @discardableResult
    func apply(dryRun: Bool = false) async -> String {
        guard let p = posting else { return "공고 없음" }
        loadTask?.cancel()
        failed = false
        applyNote = nil
        web.interactive = false
        do {
            status = "HY-WEP 목록에서 이 공고 찾는 중…"
            if !HyEngine.sessionFresh || !web.url.contains("hywep.hanyang.ac.kr") {
                guard let (u, pw) = await hyCreds.load() else { throw WebError.noCredentials }
                try await HyEngine.login(web, u, pw)
            } else if !web.url.contains("list.do") {
                try await web.go(hyListURL)
            }
            if !(await web.exists(HyEngine.scheduleTabs)) {
                guard let (u, pw) = await hyCreds.load() else { throw WebError.noCredentials }
                try await HyEngine.login(web, u, pw)
            }
            // 어느 학기 탭·페이지에 있는지 찾기 (목록 조회 POST만)
            let found = try await web.js(#"""
                const scheds = [...document.querySelectorAll('li[onclick^="schedule("]')].map(li => li.getAttribute('onclick').match(/\d+/)[0]);
                for (const s of scheds) {
                  for (let pg = 0; pg < 60; pg++) {
                    const body = new URLSearchParams({schedule: s, comp_code: '', pg: String(pg), status: '1137', year: '', term_div: '',
                      status_comp: '1047', intern_div: '', major_nm: '', comp_name: '', dept: ''});
                    const r = await fetch('/compjoinsearch/list.do', {method: 'POST', body, credentials: 'include'});
                    const html = await r.text();
                    if (html.includes("goView('" + jid + "')")) return body.toString();
                    const doc = new DOMParser().parseFromString(html, 'text/html');
                    if ([...doc.querySelectorAll('a[href*="goView"]')].length < 50) break;
                  }
                }
                return '';
                """#, ["jid": p.jid]) as? String ?? ""
            if found.isEmpty { throw WebError.other("HY-WEP 목록에서 이 공고를 못 찾았어. 접수가 끝났을 수 있어.") }
            // 그 목록 페이지를 창에 실제로 띄움
            var req = URLRequest(url: URL(string: hyListURL)!)
            req.httpMethod = "POST"
            req.httpBody = found.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(hyListURL, forHTTPHeaderField: "Referer")
            try await web.go(req)
            let info = try await web.js(#"""
                const a = document.querySelector(`a[href="javascript:goView('${jid}');"]`);
                const tr = a && a.closest('tr');
                if (!tr) return 'norow';
                tr.scrollIntoView({block: 'center'});
                tr.style.outline = '3px solid #f59e0b'; tr.style.background = '#fff7e6';
                const btn = [...tr.querySelectorAll('a,button,input[type=button]')]
                  .find(e => (e.innerText || e.value || '').replace(/\s+/g, '') === '신청하기');
                if (!btn) {
                  const last = (tr.lastElementChild ? tr.lastElementChild.innerText : '').replace(/\s+/g, ' ').trim();
                  return 'nobtn:' + last;
                }
                if (!dry) setTimeout(() => btn.click(), 300);
                return 'ok:' + (btn.getAttribute('onclick') || '').slice(0, 80);
                """#, ["jid": p.jid, "dry": dryRun]) as? String ?? ""
            status = nil
            if info == "norow" { throw WebError.other("목록 페이지에서 이 공고 줄을 못 찾았어.") }
            if info.hasPrefix("nobtn:") {
                let last = String(info.dropFirst(6))
                applyNote = "이 공고에는 '신청하기' 버튼이 없어" + (last.isEmpty ? "." : " (\(last)).") + " 이미 신청했거나 신청할 수 없는 상태일 수 있어. 표시된 줄을 확인해줘."
                return info
            }
            if !dryRun {
                web.interactive = true  // 사이트의 확인 창을 사용자에게 그대로 보여줌
                applyNote = "HY-WEP의 '신청하기'를 눌렀어. 뜨는 확인 창에서 [확인]을 눌러야 실제로 신청돼."
            }
            return info
        } catch {
            if Task.isCancelled { return "취소됨" }
            failed = true
            status = error.message
            return "FAIL " + error.message
        }
    }
}

// MARK: - 공고 스크린샷 (페이지 전체를 PNG로)

enum ShotFolder {
    static let key = "screenshotDir"
    static var url: URL? {
        get { UserDefaults.standard.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: key) }
    }

    /// 폴더 고르기 창. 고르면 저장하고 돌려줌.
    @MainActor static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더에 저장"
        panel.message = "공고 스크린샷을 저장할 폴더를 골라줘"
        panel.directoryURL = url ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let u = panel.url else { return nil }
        url = u
        return u
    }

    static var displayName: String {
        guard let u = url else { return "지정 안 됨" }
        return (u.path as NSString).abbreviatingWithTildeInPath
    }
}

extension DetailController {
    /// 지금 창에 열린 공고 페이지 전체를 PNG로 저장. 폴더가 없으면 먼저 고르게 함.
    func saveScreenshot(to folder: URL? = nil) async {
        guard let p = posting else { return }
        guard let dir = folder ?? ShotFolder.url ?? ShotFolder.choose() else { return }
        do {
            guard web.url.contains("view_stu.do") else { throw WebError.other("공고 페이지가 열린 뒤에 찍어줘.") }
            let png = try await Self.fullPagePNG(web.webView)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let day = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
            let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
            let clean = { (x: String) in x.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            var name = [clean(p.comp), clean(p.dept)].filter { !$0.isEmpty }.joined(separator: " - ")
            if name.count > 80 { name = String(name.prefix(80)) }
            let file = dir.appendingPathComponent("\(name) (\(p.jid), \(day)).png")
            try png.write(to: file, options: .atomic)
            shotNote = ("저장했어: \(file.lastPathComponent)", file)
        } catch {
            shotNote = ("스크린샷 저장 실패: \(error.message)", nil)
        }
    }

    /// WKWebView 내용 전체(스크롤 아래까지)를 한 장의 PNG로. createPDF로 전체를 받은 뒤 2배 해상도로 그림.
    static func fullPagePNG(_ wv: WKWebView) async throws -> Data {
        let pdf: Data = try await withCheckedThrowingContinuation { cont in
            wv.createPDF(configuration: WKPDFConfiguration()) { cont.resume(with: $0) }
        }
        guard let rep = NSPDFImageRep(data: pdf), rep.pageCount > 0 else { throw WebError.other("페이지를 그리지 못했어.") }
        let size = rep.bounds.size
        let scale: CGFloat = 2
        guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw WebError.other("이미지를 만들지 못했어.")
        }
        bmp.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bmp.representation(using: .png, properties: [:]) else { throw WebError.other("PNG로 바꾸지 못했어.") }
        return png
    }
}

struct DetailView: View {
    @ObservedObject var ctl: DetailController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ctl.posting?.comp ?? "").font(.headline)
                    Text([ctl.posting?.dept, ctl.posting?.loc].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let store = ctl.store, let p = ctl.posting {
                    DetailBookmarkButton(store: store, posting: p)
                }
                if let h = ctl.posting?.home, !h.isEmpty {
                    Button { openURL(h) } label: { Label("기관 홈페이지", systemImage: "building.2") }
                }
                Menu {
                    Text("저장 폴더: \(ShotFolder.displayName)")
                    Button("저장 폴더 바꾸기…") { if ShotFolder.choose() != nil { Task { await ctl.saveScreenshot() } } }
                    if let u = ShotFolder.url {
                        Button("저장 폴더 열기") { NSWorkspace.shared.open(u) }
                    }
                } label: {
                    Label("스크린샷", systemImage: "camera")
                } primaryAction: {
                    Task { await ctl.saveScreenshot() }
                }
                .fixedSize()
                .disabled(ctl.status != nil)
                .help("공고 페이지 전체를 PNG로 저장해. 오른쪽 ▾에서 저장 폴더를 바꿀 수 있어")
                Button { Task { await ctl.apply() } } label: { Label("지원하기", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(ctl.status != nil && !ctl.failed)
                    .help("HY-WEP 목록에서 이 공고의 '신청하기'를 눌러줘. 사이트 확인 창에서 [확인]을 눌러야 신청돼")
                Button { ctl.reload(forceLogin: true) } label: { Label("다시 불러오기", systemImage: "arrow.clockwise") }
                    .help("로그인이 풀렸으면 다시 로그인해서 열어")
            }
            .padding(10)
            if let n = ctl.shotNote {
                HStack(spacing: 8) {
                    Image(systemName: n.file == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(n.file == nil ? .orange : .green)
                    Text(n.text).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let f = n.file {
                        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                    Button { ctl.shotNote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background((n.file == nil ? Color.orange : Color.green).opacity(0.12))
            }
            if let n = ctl.applyNote {
                HStack(spacing: 8) {
                    Image(systemName: "hand.point.right.fill").foregroundStyle(.orange)
                    Text(n).font(.callout)
                    Spacer()
                    Button("공고 내용으로 돌아가기") { ctl.reload(forceLogin: false) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(.orange.opacity(0.12))
            }
            Divider()
            ZStack {
                WebViewHost(webView: ctl.web.webView)
                if let s = ctl.status {
                    VStack(spacing: 10) {
                        if ctl.failed {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        } else {
                            ProgressView()
                        }
                        Text(s).multilineTextAlignment(.center).frame(maxWidth: 420)
                        if ctl.failed { Button("다시 시도") { ctl.reload(forceLogin: true) } }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            HStack {
                Image(systemName: "info.circle")
                Text("‘지원하기’는 사이트의 신청하기 버튼을 대신 눌러줄 뿐이야. 사이트 확인 창에서 [확인]을 눌러야 실제로 신청돼.")
            }
            .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

/// 공고 상세 창들. 같은 공고를 다시 열면 그 창을 앞으로, 다른 공고는 새 창으로 엶.
@MainActor
final class DetailWindows {
    weak var store: HyStore?
    private var open: [String: DetailController] = [:]
    private var order: [String] = []

    func open(_ p: Posting) {
        if let c = open[p.jid] { c.open(p); return }
        let prev = order.last.flatMap { open[$0]?.window }
        let c = DetailController()
        c.store = store
        c.onClose = { [weak self] in
            self?.open[p.jid] = nil
            self?.order.removeAll { $0 == p.jid }
        }
        open[p.jid] = c
        order.append(p.jid)
        c.open(p, cascadeFrom: prev)
    }
}

/// 상세 창 맨 위 북마크 버튼. 목록의 북마크와 같은 값을 씀.
struct DetailBookmarkButton: View {
    @ObservedObject var store: HyStore
    let posting: Posting

    var body: some View {
        let on = store.isBookmarked(posting)
        Button { store.toggleBookmark(posting) } label: {
            Label {
                Text(on ? "북마크됨" : "북마크")
            } icon: {
                Image(systemName: on ? "star.fill" : "star").foregroundStyle(on ? .yellow : .secondary)
            }
        }
        .help(on ? "북마크 해제" : "북마크하면 목록 맨 위에 고정돼")
    }
}

// MARK: - 이력서 수정 창 (MY PAGE → 이력서 작성 버튼 경유. 직접 주소로 들어가면 사이트가 막음)

@MainActor
final class ResumeController: ObservableObject {
    let web = WebSession(hidden: false)
    @Published var status: String?
    @Published var failed = false
    @Published var note: String?
    private var window: NSWindow?
    private var loadTask: Task<Void, Never>?

    func open() {
        if window == nil {
            window = Windows.make("이력서 수정", size: NSSize(width: 1100, height: 880), autosave: "resume", ResumeView(ctl: self))
        }
        Windows.present(window!)
        if loadTask == nil || failed || web.url.isEmpty { reload(forceLogin: false) }
    }

    func reload(forceLogin: Bool) {
        loadTask?.cancel()
        loadTask = Task { await load(forceLogin: forceLogin) }
    }

    private func load(forceLogin: Bool) async {
        failed = false
        note = nil
        web.interactive = false
        do {
            if forceLogin || !HyEngine.sessionFresh {
                status = "HY-WEP 로그인 중…"
                guard let (u, pw) = await hyCreds.load() else { throw WebError.noCredentials }
                try await HyEngine.login(web, u, pw)
                if Task.isCancelled { return }
            }
            status = "MY PAGE 여는 중…"
            web.clearAlerts()
            try await web.go(hyHome + "/studentMain/dashBoard.do")
            if !web.url.contains("dashBoard") || !web.alerts.isEmpty {
                if !forceLogin { return await load(forceLogin: true) }
                throw WebError.other("MY PAGE를 못 열었어 \(web.alerts.last ?? "")")
            }
            status = "이력서 작성 화면 여는 중…"
            let clicked = try await web.js("""
                const a = document.querySelector('a[href*="/studentcareer/regedit.do"]');
                if (!a) return false;
                a.click();
                return true;
                """) as? Bool ?? false
            if clicked {
                try? await web.until(20, "이력서 화면") { self.web.url.contains("regedit.do") && !self.web.webView.isLoading }
            } else {
                note = "MY PAGE에서 이력서 작성 버튼을 못 찾았어. 아래 화면의 '이력서 작성' 항목에서 직접 눌러줘."
            }
            web.interactive = true  // 저장 확인 창·사진 첨부 등을 사용자에게 그대로 보여줌
            status = nil
        } catch {
            if Task.isCancelled { return }
            failed = true
            status = error.message
        }
    }
}

struct ResumeView: View {
    @ObservedObject var ctl: ResumeController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("이력서 · 자기소개서 수정").font(.headline)
                    Text("HY-WEP MY PAGE의 이력서 작성 화면이야. 다 쓰면 페이지 안의 저장 버튼을 눌러줘.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { ctl.reload(forceLogin: false) } label: { Label("처음 화면으로", systemImage: "arrow.uturn.backward") }
                    .help("MY PAGE를 거쳐 이력서 작성 화면을 다시 열어 (저장 안 한 내용은 사라져)")
            }
            .padding(10)
            if let n = ctl.note {
                HStack { Image(systemName: "hand.point.right.fill").foregroundStyle(.orange); Text(n).font(.callout); Spacer() }
                    .padding(.horizontal, 10).padding(.vertical, 8).background(.orange.opacity(0.12))
            }
            Divider()
            ZStack {
                WebViewHost(webView: ctl.web.webView)
                if let s = ctl.status {
                    VStack(spacing: 10) {
                        if ctl.failed {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        } else {
                            ProgressView()
                        }
                        Text(s).multilineTextAlignment(.center).frame(maxWidth: 420)
                        if ctl.failed { Button("다시 시도") { ctl.reload(forceLogin: true) } }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - 화면 상태

@MainActor
final class HyStore: ObservableObject {
    @Published var data: HyData?
    @Published var running: Date?
    @Published var runMessage = ""
    @Published var error: String?
    var openSettings: () -> Void = {}
    let detail = DetailWindows()
    let resume = ResumeController()

    init() { detail.store = self }
    private var loadedAt: Date?
    /// 북마크한 공고 jid. 목록 맨 위에 뜸. 공고가 내려가도 기록은 남겨 둠(다시 올라오면 그대로 북마크).
    @Published private(set) var bookmarks = Set(UserDefaults.standard.stringArray(forKey: "bookmarks") ?? [])

    func isBookmarked(_ p: Posting) -> Bool { bookmarks.contains(p.jid) }

    func toggleBookmark(_ p: Posting) {
        if bookmarks.remove(p.jid) == nil { bookmarks.insert(p.jid) }
        UserDefaults.standard.set(bookmarks.sorted(), forKey: "bookmarks")
    }

    func load() {
        data = hyFiles.load(HyData.self, hyResultFile)
        loadedAt = hyFiles.mtime(hyResultFile)
    }

    func reloadIfChanged() {
        if running == nil, let m = hyFiles.mtime(hyResultFile), m != loadedAt { load() }
    }

    func check(reset: Bool = false) {
        guard running == nil else { return }
        running = Date()
        error = nil
        Task {
            defer { running = nil }
            do {
                _ = try await HyEngine.run(reset: reset) { [weak self] in self?.runMessage = $0 }
                DailyGuard().markDone()
                load()
            } catch {
                self.error = error.message
                hyFiles.log("지금 확인 실패: \(error.message)")
            }
        }
    }
}

// MARK: - 목록 화면

struct HyContentView: View {
    @ObservedObject var store: HyStore
    @State private var query = ""
    @State private var onlyNew = false
    @State private var hideClosed = true
    @State private var onlyBookmarks = false
    @State private var selection = Set<Posting.ID>()
    @State private var sortOrder = [KeyPathComparator(\Posting.jidNum, order: .reverse)]
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var rows: [Posting] {
        guard let d = store.data else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = d.rows.filter { r in
            (!onlyNew || r.is_new) && (!hideClosed || r.daysLeft >= 0) && (!onlyBookmarks || store.isBookmarked(r)) &&
                (q.isEmpty || [r.comp, r.dept, r.major, r.loc, r.cat, r.type, r.sched].contains { $0.lowercased().contains(q) })
        }.sorted(using: sortOrder)
        // 북마크한 공고는 정렬과 상관없이 맨 위 (그 안에서는 지금 정렬 순서 유지)
        return sorted.filter(store.isBookmarked) + sorted.filter { !store.isBookmarked($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = store.error { ErrorBanner(message: e) { store.error = nil } }
            Divider()
            if store.data == nil { empty } else { table }
        }
        .frame(minWidth: 900, minHeight: 500)
        .onReceive(timer) { _ in store.reloadIfChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.reloadIfChanged()
        }
    }

    var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("HY-WEP 접수중 공고").font(.title2.bold())
                        if let d = store.data, d.new_count > 0 {
                            Text("새 공고 \(d.new_count)").font(.callout.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 2).background(.orange, in: Capsule())
                        }
                    }
                    if store.running != nil {
                        Text(store.runMessage).font(.callout).foregroundStyle(.secondary)
                    } else if let d = store.data, let t = DateUtil.parse(d.checked_at) {
                        Text("총 \(d.total)건 · 표시 \(rows.count)건 · 마지막 확인 \(DateUtil.label(t)) (\(DateUtil.relative(t)))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let s = store.running { RunningIndicator(since: s, message: "") }
                Button { store.check() } label: { Label("지금 확인", systemImage: "arrow.clockwise") }
                    .disabled(store.running != nil)
                Button { store.resume.open() } label: { Label("이력서 수정", systemImage: "doc.text") }
                    .help("HY-WEP 이력서·자기소개서 작성 화면을 앱 안에서 열어")
                Button { openURL(hyListURL) } label: { Label("HY-WEP 사이트", systemImage: "safari") }
                Button { store.openSettings() } label: { Image(systemName: "gearshape") }.help("설정 (⌘,)")
            }
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("기관·부서·전공·지역 검색 (예: 자동차, 로봇, 판교)", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 420)
                Toggle("새 공고만", isOn: $onlyNew).toggleStyle(.checkbox)
                Toggle("북마크만", isOn: $onlyBookmarks).toggleStyle(.checkbox)
                Toggle("마감 지난 것 숨기기", isOn: $hideClosed).toggleStyle(.checkbox)
                Spacer()
                Text("더블클릭: 상세 보기 · ☆: 북마크(맨 위 고정)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    var empty: some View {
        ContentUnavailableView {
            Label("아직 확인 결과가 없어", systemImage: "tray")
        } description: {
            Text("‘지금 확인’을 누르면 접수중 공고를 전부 가져와. (10~20초)")
        } actions: {
            Button("지금 확인") { store.check() }.disabled(store.running != nil)
        }
    }

    var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { r in
                let on = store.isBookmarked(r)
                Button { store.toggleBookmark(r) } label: {
                    Image(systemName: on ? "star.fill" : "star").foregroundStyle(on ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(on ? "북마크 해제" : "북마크 (목록 맨 위에 고정)")
            }.width(22)
            TableColumn("발견", value: \.found) { r in
                if r.is_new {
                    Text("NEW").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.orange, in: Capsule())
                } else {
                    Text(r.foundLabel).foregroundStyle(.secondary)
                }
            }.width(min: 44, ideal: 52, max: 70)
            TableColumn("기관", value: \.comp) { r in Text(r.comp).fontWeight(.semibold).help(r.comp) }
                .width(min: 120, ideal: 170)
            TableColumn("부서", value: \.dept) { r in Text(r.dept).help(r.dept) }.width(min: 80, ideal: 130)
            TableColumn("모집마감", value: \.daysLeft) { r in
                let n = r.daysLeft
                let tag = n == 9999 ? r.deadline : n == 0 ? "D-DAY" : n > 0 ? "D-\(n)" : "마감"
                let date = r.deadlineDate.map { DateUtil.label($0, time: false) } ?? ""
                Text("\(tag) · \(date) \(r.dtime)")
                    .monospacedDigit()
                    .foregroundStyle(n <= 2 && n >= 0 ? .red : n < 0 ? .secondary : .primary)
                    .fontWeight(n <= 2 && n >= 0 ? .semibold : .regular)
            }.width(min: 120, ideal: 160)
            TableColumn("실습기간", value: \.period).width(min: 90, ideal: 150)
            TableColumn("지원금", value: \.pay).width(min: 60, ideal: 100)
            Group {
                TableColumn("모집전공", value: \Posting.major) { r in Text(r.major).foregroundStyle(.secondary).help(r.major) }
                    .width(min: 100, ideal: 220)
                TableColumn("모집/지원", value: \Posting.quota) { r in Text("\(r.quota) / \(r.applied)").monospacedDigit() }
                    .width(min: 50, ideal: 64)
                TableColumn("소재지", value: \Posting.loc).width(min: 60, ideal: 90)
                TableColumn("학기·분류", value: \Posting.sched) { r in
                    Text("\(r.shortSched) · \(r.cat)").foregroundStyle(.secondary).help("\(r.sched)\n\(r.cat) · \(r.type)")
                }.width(min: 90, ideal: 160)
            }
        }
        .contextMenu(forSelectionType: Posting.ID.self) { ids in
            if ids.count > 1 {
                Button("공고 상세 \(ids.count)개 열기") { for id in ids { if let r = posting(id) { store.detail.open(r) } } }
            } else if let r = posting(ids.first) {
                Button("공고 상세 보기") { store.detail.open(r) }
                Button(store.isBookmarked(r) ? "북마크 해제" : "북마크") { store.toggleBookmark(r) }
                if !r.home.isEmpty { Button("기관 홈페이지 열기") { openURL(r.home) } }
                Button("기관명 복사") { copyToPasteboard(r.comp) }
            }
        } primaryAction: { ids in
            for id in ids { if let r = posting(id) { store.detail.open(r) } }
        }
    }

    func posting(_ id: Posting.ID?) -> Posting? {
        guard let id else { return nil }
        return store.data?.rows.first { $0.id == id }
    }
}

struct HySettingsView: View {
    @ObservedObject var store: HyStore
    let rerunSetup: () -> Void
    @State private var confirmReset = false

    var body: some View {
        Form {
            CredentialSection(title: "한양대 포털 계정", creds: hyCreds)
            AutoRunSection(agent: hyAgent, action: "새 공고가 있으면 창을 띄워줘")
            Section {
                Button("기준 목록 초기화…", role: .destructive) { confirmReset = true }
                    .disabled(store.running != nil)
                Text("지금 접수중인 공고를 새 기준으로 다시 저장해. 그 뒤로 올라온 공고만 NEW로 표시돼.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("기준 목록") }
            Section {
                Button("오류 기록 보기") { NSWorkspace.shared.open(hyFiles.url("error.log")) }
                Button("데이터 폴더 열기") { NSWorkspace.shared.open(hyFiles.dir) }
                Button("처음 설정 다시 하기") { rerunSetup() }
            } header: { Text("기타") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .confirmationDialog("기준 목록을 초기화할까?", isPresented: $confirmReset) {
            Button("초기화", role: .destructive) { store.check(reset: true) }
        } message: {
            Text("지금까지 본 공고 기록이 지워지고 현재 공고로 다시 만들어져.")
        }
    }
}

// MARK: - 앱 수명주기

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HyStore()
    var mainWindow: NSWindow?
    var settingsWindow: NSWindow?
    var setupWindow: NSWindow?
    var autoRunning = false
    let args = CommandLine.arguments

    func applicationDidFinishLaunching(_ n: Notification) {
        Migration.defaults("hywepchecker")
        Notifier.shared.setUp()
        Windows.installMenu(appName: "HY-WEP 체커", target: self, settings: #selector(showSettings), refresh: #selector(refresh))
        store.openSettings = { [weak self] in self?.showSettings() }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.quitIfNoWindows() }
        }
        HyEngine.importLegacySeen()
        if args.contains("--selftest") { Task { await selfTest() }; return }
        if args.contains("--auto") {
            NSApp.setActivationPolicy(.accessory)
            Task { await runAuto() }
            return
        }
        Task {
            await Migration.agents("hywepchecker", current: hyAgent)
            await hyAgent.refreshIfMoved()
            // 이미 허용/거부했으면 아무것도 안 뜸. 앱 ID가 바뀐 뒤 처음 열 때만 macOS가 다시 물어봄
            if UserDefaults.standard.bool(forKey: "setupDone") { Notifier.shared.requestPermission() }
            if UserDefaults.standard.bool(forKey: "setupDone") { showMain() } else { showSetup() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { UserDefaults.standard.bool(forKey: "setupDone") ? showMain() : showSetup() }
        return true
    }

    private func quitIfNoWindows() {
        let visible = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        if visible.isEmpty && !autoRunning { NSApp.terminate(nil) }
    }

    func showMain() {
        if mainWindow == nil {
            mainWindow = Windows.make("HY-WEP 체커", size: NSSize(width: 1280, height: 780), autosave: "main", HyContentView(store: store))
        }
        store.load()
        Windows.present(mainWindow!)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = Windows.make("설정", size: NSSize(width: 480, height: 600), resizable: false,
                                          HySettingsView(store: store, rerunSetup: { [weak self] in
                                              self?.settingsWindow?.close()
                                              self?.showSetup()
                                          }))
        }
        Windows.present(settingsWindow!)
    }

    @objc func refresh() {
        showMain()
        store.check()
    }

    func showSetup() {
        setupWindow?.close()
        let view = SetupView(
            appName: "HY-WEP 체커", icon: "briefcase.fill", tint: .teal,
            features: ["HY-WEP 현장실습 접수중 공고를 한눈에 (검색·정렬·필터)", "새로 올라온 공고에 NEW 표시",
                       "공고를 더블클릭하면 상세 내용을 앱 안에서 바로 확인", "정한 시각에 자동으로 확인해서 새 공고를 알려줌",
                       "자동 확인은 읽기 전용 — 신청은 내가 ‘지원하기’를 누를 때만"],
            accountTitle: "HY-WEP 학생 로그인에 쓰는 한양대 포털 계정을 입력해줘.",
            creds: hyCreds, agent: hyAgent,
            autoAction: "새 공고가 있으면 창을 띄워줘",
            testLogin: { try await HyEngine.testLogin($0, $1) },
            onFinish: { [weak self] in
                guard let self else { return }
                self.showMain()
                self.setupWindow?.close()
                self.store.check()
            })
        setupWindow = Windows.make("HY-WEP 체커 설정", size: NSSize(width: 520, height: 480), resizable: false, view)
        Windows.present(setupWindow!)
    }

    // launchd(--auto): 설정한 시각마다 1번. 새 공고가 있으면 창, 없으면 알림만.
    func runAuto() async {
        let guardian = DailyGuard()
        guard UserDefaults.standard.bool(forKey: "setupDone"), guardian.shouldRun(), hyFiles.lock() else {
            NSApp.terminate(nil); return
        }
        autoRunning = true
        defer { hyFiles.unlock(); autoRunning = false }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let d = try await HyEngine.run()
                guardian.markDone()
                if d.first_run {
                    Notifier.shared.post("HY-WEP 체커", "접수중 공고 \(d.total)건을 기준으로 저장했어. 다음 확인부터 새 공고만 알려줄게.")
                    return finishAuto(show: true)
                }
                if d.new_count == 0 {
                    Notifier.shared.post("HY-WEP", "새 공고 없음 (접수중 \(d.total)건)")
                    return finishAuto(show: false)
                }
                let names = d.rows.filter(\.is_new).prefix(3).map(\.comp).joined(separator: ", ")
                Notifier.shared.post("HY-WEP 새 공고 \(d.new_count)건", names + (d.new_count > 3 ? " 외" : ""))
                return finishAuto(show: true)
            } catch {
                lastError = error
                hyFiles.log("자동 실행 실패(\(attempt + 1)/3): \(error.message)")
                if !error.isTransient { break }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        let e = lastError!
        if e.isTransient && guardian.recordFailure() < 3 { return finishAuto(show: false) }
        if e.isTransient { guardian.markDone() } else { guardian.stopForToday() }  // 로그인 거부 반복 → 계정 잠김 방지
        Notifier.shared.post("HY-WEP 체커 오류", e.message)
        store.error = e.message
        finishAuto(show: true)
    }

    private func finishAuto(show: Bool) {
        if show && !otherInstanceRunning() {
            showMain()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    // 개발용: --selftest [--detail] → 수집 결과 요약 출력 (seen/latest 저장 안 함)
    func selfTest() async {
        let t = Date()
        do {
            guard let (u, p) = await hyCreds.load() else { throw WebError.noCredentials }
            let web = WebSession()
            try await HyEngine.login(web, u, p)
            let rows = try await HyEngine.collect(web)
            print("OK \(Int(Date().timeIntervalSince(t)))s rows=\(rows.count)", rows.first.map { "\($0.jid) \($0.comp) \($0.home)" } ?? "")
            // 같은 프로세스에서 두 번째 로그인 (세션 살아 있는 상태) — 설정 마법사 직후 / 상세 창 재로그인 경로
            let web2 = WebSession()
            try await HyEngine.login(web2, u, p)
            print("SECOND LOGIN OK", web2.url)
            web2.close()
            // 이력서 수정 창: MY PAGE 경유로 이력서 화면까지 열리는지 (보기만, 저장 안 함)
            if args.contains("--resume") {
                let c = ResumeController()
                c.web.webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
                c.reload(forceLogin: false)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                for _ in 0..<80 where c.status != nil { try await Task.sleep(nanoseconds: 500_000_000) }
                let text = (try? await c.web.js("return document.body.innerText.replace(/\\s+/g,' ').slice(0, 300);")) as? String ?? ""
                print("RESUME url=\(c.web.url) status=\(c.status ?? "ok") note=\(c.note ?? "-") alerts=\(c.web.alerts)\n\(text)")
            }
            // 지원하기 흐름을 '찾기'까지만 (누르지 않음)
            if args.contains("--applydry") {
                let d = DetailController()
                for r in rows.sorted(by: { $0.jidNum > $1.jidNum }).prefix(2) {
                    d.posting = r
                    let info = await d.apply(dryRun: true)
                    print("APPLYDRY \(r.jid) \(r.comp): \(info) note=\(d.applyNote ?? "-") url=\(d.web.url)")
                }
            }
            if args.contains("--detail"), let r = rows.first {
                let d = DetailController()
                d.web.webView.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
                d.posting = r
                d.reload(forceLogin: false)
                for _ in 0..<60 where d.status != nil || d.web.url.isEmpty {
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let text = (try? await d.web.js("return document.body.innerText.slice(0, 400);")) as? String ?? ""
                print("DETAIL url=\(d.web.url) status=\(d.status ?? "ok") alerts=\(d.web.alerts)\n\(text)")
                if let i = args.firstIndex(of: "--shot"), i + 1 < args.count {
                    await d.saveScreenshot(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                    print("SHOT \(d.shotNote?.text ?? "-") \(d.shotNote?.file?.path ?? "")")
                }
            }
        } catch {
            print("FAIL", error.message)
        }
        exit(0)
    }
}

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
