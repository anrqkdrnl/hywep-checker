// 두 앱(LMS 체커 / HY-WEP 체커)이 같이 쓰는 코드.
// - 앱 안 브라우저(WKWebView)로 로그인·조회 (Python/터미널 불필요)
// - 키체인, launchd 자동 실행, 하루 1회 가드, 알림, 창/메뉴, 설정 마법사
import AppKit
import SwiftUI
import UserNotifications
import WebKit

// MARK: - 프로세스 실행 (security / launchctl 용)

enum Shell {
    struct Result {
        let code: Int32
        let out: String
        let err: String
    }

    static func run(_ exe: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(code: -1, out: "", err: error.localizedDescription))
                    return
                }
                var outData = Data(), errData = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { outData = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { errData = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(code: p.terminationStatus,
                                              out: String(decoding: outData, as: UTF8.self),
                                              err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

// MARK: - 키체인
// /usr/bin/security 를 거쳐 저장한다. 앱을 다시 빌드해도(서명이 바뀌어도) 접근 허용 팝업이 뜨지 않게.

enum Keychain {
    static var account: String { NSUserName() }

    static func read(_ service: String) async -> String {
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service, "-w"])
        return r.code == 0 ? r.out.trimmingCharacters(in: .newlines) : ""
    }

    static func exists(_ service: String) async -> Bool {
        await Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service]).code == 0
    }

    @discardableResult
    static func write(_ service: String, _ value: String) async -> Bool {
        await Shell.run("/usr/bin/security",
                        ["add-generic-password", "-U", "-a", account, "-s", service, "-w", value]).code == 0
    }

    static func delete(_ service: String) async {
        _ = await Shell.run("/usr/bin/security", ["delete-generic-password", "-a", account, "-s", service])
    }
}

/// 앱마다 키체인 서비스 이름 한 쌍
struct Credentials {
    let idService: String
    let pwService: String

    func load() async -> (String, String)? {
        let u = await Keychain.read(idService), p = await Keychain.read(pwService)
        return u.isEmpty || p.isEmpty ? nil : (u, p)
    }

    func isSet() async -> Bool {
        let a = await Keychain.exists(idService)
        let b = await Keychain.exists(pwService)
        return a && b
    }
}

// MARK: - launchd 자동 실행 (앱 실행 파일을 --auto 로 10분마다 깨움, 실제 확인은 설정한 시각마다 1번)

struct LaunchAgent {
    let label: String
    var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    private var domain: String { "gui/\(getuid())" }
    var exists: Bool { FileManager.default.fileExists(atPath: plistPath) }

    func isLoaded() async -> Bool {
        await Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).code == 0
    }

    func programArguments() -> [String] {
        (NSDictionary(contentsOfFile: plistPath)?["ProgramArguments"] as? [String]) ?? []
    }

    /// 앱이 지워졌으면(업데이트 중 잠깐 빈 경우를 피하려고 90초 기다려 다시 확인) 스스로 등록을 지움
    static let runner = """
        if [ ! -x "$0" ]; then sleep 90; fi
        if [ -x "$0" ]; then exec "$0" --auto; fi
        rm -f "$1"
        /bin/launchctl bootout "gui/$(id -u)/$2"
        """

    func desiredArguments(_ exe: String) -> [String] {
        ["/bin/sh", "-c", LaunchAgent.runner, exe, plistPath, label]
    }

    /// 현재 앱 위치로 plist를 쓰고 등록. 실패하면 오류 메시지.
    func install() async -> String? {
        guard let exe = Bundle.main.executablePath else { return "실행 파일 경로를 모름" }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": desiredArguments(exe),
            "RunAtLoad": false,
            "StartInterval": 600,
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath))
        } catch { return error.localizedDescription }
        UserDefaults.standard.set(true, forKey: "autoEnabled")
        _ = await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let r = await Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
        return r.code == 0 ? nil : (r.err.isEmpty ? "launchctl 오류 \(r.code)" : r.err)
    }

    func uninstall() async {
        UserDefaults.standard.set(false, forKey: "autoEnabled")
        _ = await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// 앱을 다른 폴더로 옮겼거나 예전 형식이면 plist 갱신.
    /// 자동 확인을 켜뒀는데 등록이 사라졌으면(앱 삭제 후 재설치, brew 업데이트 등) 다시 등록.
    func refreshIfMoved() async {
        guard let exe = Bundle.main.executablePath else { return }
        if exists {
            UserDefaults.standard.set(true, forKey: "autoEnabled")
            if programArguments() != desiredArguments(exe) { _ = await install() }
        } else if UserDefaults.standard.bool(forKey: "autoEnabled") {
            _ = await install()
        }
    }
}

// MARK: - 저장 위치 / 로그

struct AppFiles {
    let dir: URL

    init(_ name: String) {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func url(_ file: String) -> URL { dir.appendingPathComponent(file) }

    func log(_ msg: String) {
        let line = "[\(DateUtil.stamp(Date()))] \(msg)\n"
        let u = url("error.log")
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: u)
        }
    }

    func save<T: Encodable>(_ value: T, _ file: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: url(file), options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let d = try? Data(contentsOf: url(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    func mtime(_ file: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(file).path))?[.modificationDate] as? Date
    }

    /// 자동 실행 중복 방지 잠금. 이미 다른 프로세스가 잡고 있으면 false.
    func lock() -> Bool {
        let u = url("auto.lock")
        if let s = try? String(contentsOf: u, encoding: .utf8), let pid = Int32(s), pid != getpid(), kill(pid, 0) == 0 {
            return false
        }
        try? "\(getpid())".write(to: u, atomically: true, encoding: .utf8)
        return true
    }

    func unlock() { try? FileManager.default.removeItem(at: url("auto.lock")) }
}

// MARK: - 하루 1번 가드 + 실패 횟수 (UserDefaults)

/// 자동 확인 시각 (하루 여러 번 가능). 자정부터의 분(0~1439), 한국 시간 기준.
enum Schedule {
    static let key = "checkTimes"
    static let defaultTimes = [5 * 60]
    static let maxCount = 6

    static var times: [Int] {
        get {
            let a = (UserDefaults.standard.array(forKey: key) as? [Int]) ?? []
            let s = Array(Set(a.filter { (0..<1440).contains($0) })).sorted()
            return s.isEmpty ? defaultTimes : s
        }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: key) }
    }

    static func label(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
    static func summary(_ t: [Int] = times) -> String {
        Array(Set(t)).sorted().map(label).joined(separator: ", ")
    }
}

/// 자동 실행 회차 관리: 설정한 시각이 지나면 그 회차를 1번 실행.
/// (launchd가 10분마다 깨우므로 설정 시각 후 10분 안에, 그 시각에 Mac이 잠자고 있었으면 깨어난 뒤 실행)
struct DailyGuard {
    private let d = UserDefaults.standard

    /// 오늘 이미 지난 확인 시각 중 가장 최근 것
    func dueSlot(now: Date = Date()) -> Date? {
        let start = DateUtil.calendar.startOfDay(for: now)
        return Schedule.times.map { start.addingTimeInterval(TimeInterval($0 * 60)) }.filter { $0 <= now }.max()
    }

    var lastRunAt: Date? {
        if let t = d.object(forKey: "lastRunAt") as? Date { return t }
        // 예전 버전(날짜만 저장, 05시 고정) 호환
        if let s = d.string(forKey: "lastRun"), let day = DateUtil.parse(s) { return day.addingTimeInterval(5 * 3600) }
        return nil
    }

    func shouldRun(now: Date = Date()) -> Bool {
        if d.string(forKey: "stopDate") == DateUtil.today() { return false }
        guard let slot = dueSlot(now: now) else { return false }
        return (lastRunAt ?? .distantPast) < slot
    }

    func markDone() {
        d.set(Date(), forKey: "lastRunAt")
        for k in ["lastRun", "failSlot", "failCount", "stopDate"] { d.removeObject(forKey: k) }
    }

    /// 로그인 거부 등: 반복하면 계정이 잠길 수 있어 오늘 남은 회차는 건너뜀 (직접 확인에 성공하면 풀림)
    func stopForToday() {
        markDone()
        d.set(DateUtil.today(), forKey: "stopDate")
    }

    /// 이번 회차 실패 횟수 (+1 한 값)
    func recordFailure() -> Int {
        let slot = dueSlot().map(DateUtil.stamp) ?? DateUtil.today()
        let n = (d.string(forKey: "failSlot") == slot ? d.integer(forKey: "failCount") : 0) + 1
        d.set(slot, forKey: "failSlot")
        d.set(n, forKey: "failCount")
        return n
    }
}

// MARK: - 알림

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setUp() { UNUserNotificationCenter.current().delegate = self }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 날짜

enum DateUtil {
    static let kst = TimeZone(identifier: "Asia/Seoul")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kst
        return c
    }

    static func parse(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withFullDate]
        f.timeZone = kst
        return f.date(from: String(s.prefix(10)))
    }

    static func iso(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = ISO8601DateFormatter()
        f.timeZone = kst
        return f.string(from: d)
    }

    private static func fmt(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = kst
        f.dateFormat = pattern
        return f.string(from: d)
    }

    static func today() -> String { fmt("yyyy-MM-dd", Date()) }
    static func ymd(_ d: Date) -> String { fmt("yyyy-MM-dd", d) }
    static func md(_ d: Date) -> String { fmt("M/d", d) }
    static func stamp(_ d: Date) -> String { fmt("yyyy-MM-dd HH:mm:ss", d) }
    static func label(_ d: Date, time: Bool = true) -> String { fmt(time ? "M/d(E) HH:mm" : "M/d(E)", d) }

    static func dayDiff(_ d: Date) -> Int {
        let c = calendar
        return c.dateComponents([.day], from: c.startOfDay(for: Date()), to: c.startOfDay(for: d)).day ?? 0
    }

    static func ddayTag(_ n: Int) -> String {
        n == 0 ? "오늘" : n == 1 ? "내일" : n > 0 ? "D-\(n)" : "\(-n)일 지남"
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .full
        return f.localizedString(for: min(d, Date()), relativeTo: Date())
    }
}

// MARK: - 앱 안 브라우저

enum WebError: LocalizedError {
    case noCredentials
    case loginRejected(String)
    case timeout(String)
    case network(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "아이디/비밀번호가 저장돼 있지 않아. 설정에서 입력해줘."
        case .loginRejected(let m): return "로그인이 거부됐어: \(m)\n(아이디/비밀번호를 확인하거나, 포털 비밀번호를 바꿨으면 설정에서 다시 저장해줘)"
        case .timeout(let w): return "\(w) 응답이 없어 (네트워크 확인) — 잠시 후 다시 시도해줘"
        case .network(let m): return "인터넷 연결 오류: \(m)"
        case .other(let m): return m
        }
    }

    /// 다시 시도하면 될 수도 있는 오류인지 (로그인 거부는 재시도하면 계정이 잠길 수 있어 false)
    var isTransient: Bool {
        switch self {
        case .timeout, .network: return true
        default: return false
        }
    }
}

extension Error {
    var isTransient: Bool { (self as? WebError)?.isTransient ?? true }
    var message: String { (self as? LocalizedError)?.errorDescription ?? localizedDescription }
}

/// WKWebView 한 개를 감싼 자동화 도우미. 보이지 않는 창(화면 밖)에 붙여서 쓰거나, 보이는 창에 붙여서 쓴다.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var hiddenWindow: NSWindow?
    private(set) var alerts: [String] = []
    private var navError: String?
    /// true면 페이지의 alert/confirm을 실제 대화상자로 띄워 사용자가 직접 고르게 함 (지원하기 등).
    /// false(기본)면 자동화용: alert는 기록만, confirm은 항상 '취소'.
    var interactive = false

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init(hidden: Bool = true) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        webView.customUserAgent = WebSession.userAgent
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if hidden {
            // 화면 밖에 놓인 창: 페이지 스크립트가 정상 속도로 돌도록 창에는 붙여둔다
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 900),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = webView
            w.orderFrontRegardless()
            hiddenWindow = w
        }
    }

    func close() {
        webView.stopLoading()
        hiddenWindow?.orderOut(nil)
        hiddenWindow = nil
    }

    var url: String { webView.url?.absoluteString ?? "" }

    func clearAlerts() { alerts.removeAll() }

    func go(_ url: String, timeout: Double = 45) async throws {
        try await go(URLRequest(url: URL(string: url)!), timeout: timeout)
    }

    func go(_ req: URLRequest, timeout: Double = 45) async throws {
        navError = nil
        webView.load(req)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await until(timeout, "페이지(\(req.url?.host ?? ""))") { !self.webView.isLoading || self.navError != nil }
        if let e = navError { throw WebError.network(e) }
    }

    /// 조건이 참이 될 때까지 대기. 로그인 거부 alert가 뜨면 바로 실패.
    func until(_ timeout: Double, _ what: String, failOnAlert: Bool = false,
               _ cond: @escaping () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if failOnAlert, let a = alerts.last { throw WebError.loginRejected(a) }
            if await cond() { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        if failOnAlert, let a = alerts.last { throw WebError.loginRejected(a) }
        throw WebError.timeout(what)
    }

    /// 페이지 컨텍스트에서 async 함수 본문 실행. 반드시 값을 return 할 것.
    func js(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    }

    /// 목록 중 처음으로 존재하는 선택자 (없으면 nil)
    func first(_ selectors: [String]) async -> String? {
        let r = try? await js("for (const s of sels) { if (document.querySelector(s)) return s; } return '';", ["sels": selectors])
        guard let s = r as? String, !s.isEmpty else { return nil }
        return s
    }

    func exists(_ selector: String) async -> Bool { await first([selector]) != nil }

    /// 한양 통합 로그인 폼(#uid/#upw/#login_btn) 입력 후 제출
    func submitHanyangLogin(_ uid: String, _ pw: String) async throws {
        clearAlerts()
        _ = try await js("""
            const set = (sel, v) => { const e = document.querySelector(sel); e.focus(); e.value = v;
              e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true})); };
            set('#uid', uid); set('#upw', upw);
            setTimeout(() => document.querySelector('#login_btn').click(), 50);
            return true;
            """, ["uid": uid, "upw": pw])
    }

    func cookie(_ name: String) async -> String? {
        let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return all.first { $0.name == name && !$0.value.isEmpty }?.value
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }  // 프레임 로드 중단(리다이렉트 등)
        navError = e.localizedDescription
    }

    // WKUIDelegate — alert/confirm은 기록만 하고 닫기, 새 창은 같은 뷰에서 열기
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        alerts.append(message)
        guard interactive else { return completionHandler() }
        let a = NSAlert()
        a.messageText = "HY-WEP"
        a.informativeText = message
        a.addButton(withTitle: "확인")
        if let w = webView.window, w.isVisible {
            a.beginSheetModal(for: w) { _ in completionHandler() }
        } else {
            a.runModal(); completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        alerts.append(message)
        guard interactive else { return completionHandler(false) }
        let a = NSAlert()
        a.messageText = "HY-WEP"
        a.informativeText = message
        a.addButton(withTitle: "확인")
        a.addButton(withTitle: "취소")
        if let w = webView.window, w.isVisible {
            a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }
    }

    /// <input type="file"> (이력서 사진·첨부 등): 사용자가 고르는 경우에만
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard interactive else { return completionHandler(nil) }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        if let w = webView.window, w.isVisible {
            p.beginSheetModal(for: w) { completionHandler($0 == .OK ? p.urls : nil) }
        } else {
            completionHandler(p.runModal() == .OK ? p.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

/// SwiftUI에 WKWebView 붙이기
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - 창 / 메뉴

@MainActor
enum Windows {
    static func make<V: View>(_ title: String, size: NSSize, resizable: Bool = true, autosave: String? = nil,
                              _ view: V) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.center()
        if let autosave { w.setFrameAutosaveName(autosave) }
        return w
    }

    static func present(_ w: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 앱 메뉴 / 편집 메뉴(⌘C·⌘V가 텍스트 칸에서 동작하려면 필요) / 윈도우 메뉴
    static func installMenu(appName: String, target: AnyObject, settings: Selector, refresh: Selector) {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "\(appName) 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let s = app.addItem(withTitle: "설정…", action: settings, keyEquivalent: ",")
        s.target = target
        app.addItem(.separator())
        app.addItem(withTitle: "\(appName) 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "\(appName) 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "파일")
        let r = file.addItem(withTitle: "지금 확인", action: refresh, keyEquivalent: "r")
        r.target = target
        file.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "윈도우")
        win.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

// MARK: - 공용 뷰

struct RunningIndicator: View {
    let since: Date
    let message: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                Text("\(message) \(Int(ctx.date.timeIntervalSince(since)))초")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    let onClose: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// 설정 화면의 계정 칸
struct CredentialSection: View {
    let title: String
    let creds: Credentials
    @State private var uid = ""
    @State private var pw = ""
    @State private var hasPw = false
    @State private var msg = ""

    var body: some View {
        Section {
            TextField("아이디", text: $uid)
            SecureField("비밀번호", text: $pw, prompt: Text(hasPw ? "저장됨 — 바꿀 때만 입력" : "비밀번호"))
            HStack {
                Button("저장") { Task { await save() } }
                    .disabled(uid.isEmpty || (!hasPw && pw.isEmpty))
                Text(msg).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            Text("이 Mac의 키체인에만 저장돼. 다른 곳으로 전송되지 않아 (학교 로그인 페이지 제외).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            uid = await Keychain.read(creds.idService)
            hasPw = await Keychain.exists(creds.pwService)
        }
    }

    private func save() async {
        var ok = await Keychain.write(creds.idService, uid)
        if !pw.isEmpty {
            let ok2 = await Keychain.write(creds.pwService, pw)
            ok = ok && ok2
            if ok2 { hasPw = true }
            pw = ""
        }
        msg = ok ? "저장했어 ✓" : "저장 실패"
    }
}

/// 자동 확인 시각 편집 (여러 개)
struct ScheduleEditor: View {
    @Binding var times: [Int]
    @State private var items: [Item] = []

    private struct Item: Identifiable { let id = UUID(); var minutes: Int }

    var body: some View {
        Group {
            ForEach($items) { $item in
                HStack {
                    DatePicker("확인 시각", selection: dateBinding($item.minutes), displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, DateUtil.kst)
                        .environment(\.locale, Locale(identifier: "ko_KR"))
                    if items.count > 1 {
                        Button { items.removeAll { $0.id == item.id }; save() } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless).help("이 시각 빼기")
                    }
                }
            }
            if items.count < Schedule.maxCount {
                Button {
                    let last = items.map(\.minutes).max() ?? 0
                    var m = (last + 6 * 60) % 1440
                    while items.contains(where: { $0.minutes == m }) { m = (m + 60) % 1440 }
                    items.append(Item(minutes: m)); save()
                } label: { Label("시각 추가", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
            }
        }
        .onAppear { items = times.map { Item(minutes: $0) } }
    }

    private func dateBinding(_ m: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { DateUtil.calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(m.wrappedValue * 60)) },
            set: { d in
                let c = DateUtil.calendar.dateComponents([.hour, .minute], from: d)
                m.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                save()
            })
    }

    private func save() { times = items.map(\.minutes) }
}

func autoDescription(_ times: [Int], _ action: String) -> String {
    "매일 \(Schedule.summary(times))에 확인해서 \(action). 그 시각에 Mac이 잠자고 있었으면 깨어난 뒤 처음 쓸 때 확인해."
}

struct AutoRunSection: View {
    let agent: LaunchAgent
    /// 예: "결과 창을 띄워줘"
    let action: String
    @State private var on = false
    @State private var busy = false
    @State private var err = ""
    @State private var times = Schedule.times

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { v in
                Task {
                    busy = true
                    if v { err = await agent.install() ?? "" } else { await agent.uninstall(); err = "" }
                    on = await agent.isLoaded()
                    busy = false
                }
            })) {
                Text("자동 확인")
                Text(autoDescription(times, action)).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(busy)
            if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
            ScheduleEditor(times: $times)
                .disabled(!on)
        } header: {
            Text("자동 실행")
        }
        .onChange(of: times) { _, t in Schedule.times = t }
        .task { on = await agent.isLoaded() }
    }
}

/// 앱 번들 ID가 바뀐 경우: 예전 ID로 저장된 설정·자동 실행 등록을 지금 ID로 옮김.
/// 예전 ID는 이름 끝부분(예: "lmschecker")으로 찾는다.
enum Migration {
    private static func oldIDs(_ suffix: String) -> [String] {
        let dir = NSHomeDirectory() + "/Library/Preferences"
        let me = Bundle.main.bundleIdentifier ?? ""
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".\(suffix).plist") }
            .map { String($0.dropLast(6)) }
            .filter { $0 != me && $0.split(separator: ".").count >= 3 }
    }

    /// 설정(UserDefaults) 옮기기. 모든 실행 방식에서 맨 먼저 호출.
    static func defaults(_ suffix: String) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedOldID") else { return }
        for old in oldIDs(suffix) {
            if let dom = d.persistentDomain(forName: old) {
                for (k, v) in dom where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            }
            d.removePersistentDomain(forName: old)
        }
        d.set(true, forKey: "migratedOldID")
    }

    /// 예전 이름의 자동 실행 등록을 내리고 지움 (지금 이름으로는 refreshIfMoved가 다시 등록).
    /// 자동 실행(--auto) 중에는 자기 자신이 종료되므로 호출하지 말 것.
    static func agents(_ suffix: String, current: LaunchAgent) async {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".\(suffix).auto.plist") {
            let label = String(f.dropLast(6))
            guard label != current.label else { continue }
            _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(atPath: dir + "/" + f)
            UserDefaults.standard.set(true, forKey: "autoEnabled")
        }
    }
}

// MARK: - 처음 실행 설정 마법사

struct SetupView: View {
    let appName: String
    let icon: String
    let tint: Color
    let features: [String]
    let accountTitle: String
    let creds: Credentials
    let agent: LaunchAgent
    /// 자동 확인 때 하는 일. 예: "결과 창을 띄워줘"
    let autoAction: String
    /// 아이디/비번으로 실제 로그인 시험
    let testLogin: (String, String) async throws -> Void
    let onFinish: () -> Void

    @State private var step = 0
    @State private var uid = ""
    @State private var pw = ""
    @State private var testing = false
    @State private var error = ""
    @State private var auto = true
    @State private var notify = true
    @State private var finishing = false
    @State private var times = Schedule.times

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: account
                default: options
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
        .frame(width: 520, height: 480)
        .task { uid = await Keychain.read(creds.idService) }
    }

    var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 54)).foregroundStyle(tint)
            Text("\(appName)에 오신 걸 환영해요").font(.title.bold())
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.self) { f in
                    Label { Text(f) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(tint) }
                }
            }
            .frame(maxWidth: 400, alignment: .leading)
            Spacer()
            Button { step = 1 } label: { Text("시작하기").frame(width: 160) }
                .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. 한양대 계정 연결").font(.title2.bold())
            Text(accountTitle).foregroundStyle(.secondary)
            Form {
                TextField("포털 아이디", text: $uid)
                SecureField("비밀번호", text: $pw)
            }
            .formStyle(.grouped)
            .frame(height: 130)
            Label("아이디·비밀번호는 이 Mac의 키체인에만 저장되고, 학교 로그인 페이지 외에는 어디로도 보내지 않아요.",
                  systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button("이전") { step = 0 }
                Spacer()
                if testing { ProgressView().controlSize(.small); Text("로그인 확인 중…").foregroundStyle(.secondary) }
                Button { Task { await test() } } label: { Text("로그인 확인").frame(width: 120) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(uid.isEmpty || pw.isEmpty || testing)
            }
        }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. 자동 확인").font(.title2.bold())
            Label("로그인 성공!", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            Form {
                Toggle(isOn: $auto) {
                    Text("자동 확인")
                    Text(autoDescription(times, autoAction)).font(.caption).foregroundStyle(.secondary)
                }
                if auto { ScheduleEditor(times: $times) }
                Toggle(isOn: $notify) {
                    Text("알림 받기")
                    Text("결과를 알림 센터로도 알려줘요. 다음 화면에서 macOS가 허용 여부를 물어봐요.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 250)
            Text("시각은 나중에 설정(⌘,)에서 언제든 바꿀 수 있어요.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("이전") { step = 1 }
                Spacer()
                Button {
                    finishing = true
                    Task {
                        Schedule.times = times
                        if auto { _ = await agent.install() } else { await agent.uninstall() }
                        if notify { Notifier.shared.requestPermission() }
                        UserDefaults.standard.set(true, forKey: "setupDone")
                        onFinish()
                    }
                } label: { Text("완료하고 지금 확인").frame(width: 160) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(finishing)
            }
        }
    }

    private func test() async {
        testing = true
        error = ""
        defer { testing = false }
        do {
            try await testLogin(uid, pw)
            await Keychain.write(creds.idService, uid)
            await Keychain.write(creds.pwService, pw)
            pw = ""
            step = 2
        } catch {
            self.error = error.message
        }
    }
}

// MARK: - 기타

func openURL(_ s: String?) {
    guard let s, !s.isEmpty, let u = URL(string: s) else { return }
    NSWorkspace.shared.open(u)
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// 같은 앱이 이미 떠 있는지 (launchd가 띄운 --auto 인스턴스 포함)
func otherInstanceRunning() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .contains { $0.processIdentifier != getpid() }
}
