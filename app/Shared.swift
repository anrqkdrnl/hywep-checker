// 두 앱(LMS 체커 / HY-WEP 체커)이 같이 쓰는 코드: 프로세스 실행, 키체인, launchd, 날짜 포맷.
import AppKit
import SwiftUI

// MARK: - 프로세스 실행

enum Shell {
    struct Result {
        let code: Int32
        let out: String
        let err: String
    }

    /// 백그라운드 스레드에서 실행하고 끝나면 결과 반환. stdin은 비워둔다.
    static func run(_ exe: String, _ args: [String]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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

// MARK: - 키체인 (기존 스크립트와 같은 방식: /usr/bin/security, account = 로그인 사용자)

enum Keychain {
    static var account: String { NSUserName() }

    static func read(_ service: String) async -> String {
        let r = await Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service, "-w"])
        return r.code == 0 ? r.out.trimmingCharacters(in: .newlines) : ""
    }

    static func exists(_ service: String) async -> Bool {
        await Shell.run("/usr/bin/security", ["find-generic-password", "-a", account, "-s", service]).code == 0
    }

    static func write(_ service: String, _ value: String) async -> Bool {
        await Shell.run("/usr/bin/security",
                        ["add-generic-password", "-U", "-a", account, "-s", service, "-w", value]).code == 0
    }
}

// MARK: - launchd 자동 실행

struct LaunchAgent {
    let label: String
    var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    private var domain: String { "gui/\(getuid())" }

    func isLoaded() async -> Bool {
        await Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).code == 0
    }

    /// 실패하면 오류 메시지 반환
    func setEnabled(_ on: Bool) async -> String? {
        let r = on
            ? await Shell.run("/bin/launchctl", ["bootstrap", domain, plistPath])
            : await Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        return r.code == 0 ? nil : (r.err.isEmpty ? "launchctl 오류 \(r.code)" : r.err)
    }

    /// plist의 ProgramArguments (실행할 파이썬 경로를 알아내는 데 씀)
    func programArguments() -> [String] {
        guard let d = NSDictionary(contentsOfFile: plistPath),
              let a = d["ProgramArguments"] as? [String] else { return [] }
        return a
    }
}

// MARK: - 날짜

enum DateUtil {
    static let kst = TimeZone(identifier: "Asia/Seoul")!

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

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = kst
        return c
    }

    /// 오늘 기준 며칠 뒤인지 (날짜 단위)
    static func dayDiff(_ d: Date) -> Int {
        let c = calendar
        return c.dateComponents([.day], from: c.startOfDay(for: Date()), to: c.startOfDay(for: d)).day ?? 0
    }

    static func ddayTag(_ n: Int) -> String {
        n == 0 ? "오늘" : n == 1 ? "내일" : n > 0 ? "D-\(n)" : "\(-n)일 지남"
    }

    static func label(_ d: Date, time: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = kst
        f.dateFormat = time ? "M/d(E) HH:mm" : "M/d(E)"
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - 공용 뷰

/// 실행 중일 때 경과 시간 표시
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
            }
        }
    }
}

/// 실행 실패 배너
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

/// 아이디/비밀번호 입력 → 키체인 저장. 비밀번호는 화면에 다시 불러오지 않는다.
struct CredentialSection: View {
    let title: String
    let idService: String
    let pwService: String
    @State private var uid = ""
    @State private var pw = ""
    @State private var hasPw = false
    @State private var msg = ""

    var body: some View {
        Section {
            TextField("아이디", text: $uid)
            SecureField("비밀번호", text: $pw, prompt: Text(hasPw ? "저장됨 — 바꿀 때만 입력" : "비밀번호"))
            HStack {
                Button("키체인에 저장") { Task { await save() } }
                    .disabled(uid.isEmpty || (!hasPw && pw.isEmpty))
                Text(msg).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            Text("macOS 키체인(\(idService) / \(pwService))에만 저장돼.").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            uid = await Keychain.read(idService)
            hasPw = await Keychain.exists(pwService)
        }
    }

    private func save() async {
        var ok = await Keychain.write(idService, uid)
        if !pw.isEmpty {
            let ok2 = await Keychain.write(pwService, pw)
            ok = ok && ok2
            if ok2 { hasPw = true }
            pw = ""
        }
        msg = ok ? "저장했어 ✓" : "저장 실패"
    }
}

/// launchd 자동 실행 켜기/끄기
struct AutoRunSection: View {
    let agent: LaunchAgent
    let description: String
    @State private var on = false
    @State private var busy = false
    @State private var err = ""

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { on }, set: { v in
                Task {
                    busy = true
                    err = await agent.setEnabled(v) ?? ""
                    on = await agent.isLoaded()
                    busy = false
                }
            })) {
                Text("자동 확인")
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            .disabled(busy || !FileManager.default.fileExists(atPath: agent.plistPath))
            if !err.isEmpty { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("자동 실행")
        }
        .task { on = await agent.isLoaded() }
    }
}

/// 마지막 창을 닫으면 앱 종료
final class QuitOnCloseDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func openURL(_ s: String) {
    if let u = URL(string: s), !s.isEmpty { NSWorkspace.shared.open(u) }
}

func openFile(_ path: String, textEdit: Bool = false) {
    let url = URL(fileURLWithPath: path)
    if textEdit {
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    } else {
        NSWorkspace.shared.open(url)
    }
}

/// stderr 마지막 몇 줄만 (트레이스백 전체는 너무 김)
func tail(_ s: String, lines n: Int = 4) -> String {
    s.split(separator: "\n").suffix(n).joined(separator: "\n")
}
