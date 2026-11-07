// HY-WEP 체커.app — ~/.hywep_check/hywep_check.py 의 GUI.
// 결과는 ~/.hywep_check/latest.json (아침 자동 실행 / '지금 확인' 둘 다 여기에 씀)
import AppKit
import SwiftUI

let hyDir = NSHomeDirectory() + "/.hywep_check"
let hyJSON = hyDir + "/latest.json"
let hyPython = hyDir + "/venv/bin/python"
let hyScript = hyDir + "/hywep_check.py"
let hyAgent = LaunchAgent(label: "com.seongsu.hywepcheck")

struct Posting: Decodable, Identifiable, Hashable {
    let jid: String, sched: String, cat: String, comp: String, dept: String, home: String, loc: String
    let deadline: String, dtime: String, period: String, pay: String, type: String, major: String
    let quota: String, applied: String, found: String
    let is_new: Bool
    var id: String { jid }

    var jidNum: Int { Int(jid) ?? 0 }
    var deadlineDate: Date? { DateUtil.parse(deadline) }
    var daysLeft: Int { deadlineDate.map(DateUtil.dayDiff) ?? 9999 }
    var foundLabel: String {
        is_new ? "NEW" : found == "base" ? "기준" : found.count >= 10 ? DateUtil.parse(found).map { DateUtil.label($0, time: false) } ?? found : found
    }
    var shortSched: String {
        // "2026년도 겨울학기 단기 현장실습 (…)" → "26 겨울 단기"
        let parts = sched.split(separator: " ")
        guard parts.count >= 3, sched.contains("년도") else { return sched }
        return "\(parts[0].prefix(4).suffix(2)) \(parts[1].replacingOccurrences(of: "학기", with: "")) \(parts[2])"
    }

    enum K: String, CodingKey {
        case jid, sched, cat, comp, dept, home, loc, deadline, dtime, period, pay, type, major, quota, applied, found, is_new
    }

    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: K.self)
        func s(_ k: K) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        jid = s(.jid); sched = s(.sched); cat = s(.cat); comp = s(.comp); dept = s(.dept); home = s(.home)
        loc = s(.loc); deadline = s(.deadline); dtime = s(.dtime); period = s(.period); pay = s(.pay)
        type = s(.type); major = s(.major); quota = s(.quota); applied = s(.applied); found = s(.found)
        is_new = (try? c.decodeIfPresent(Bool.self, forKey: .is_new)) ?? false
    }
}

struct HyData: Decodable {
    let checked_at: String
    let first_run: Bool
    let total: Int
    let new_count: Int
    let list_url: String
    let rows: [Posting]
}

@MainActor
final class HyStore: ObservableObject {
    @Published var data: HyData?
    @Published var running: Date?
    @Published var error: String?

    func load() {
        guard let d = FileManager.default.contents(atPath: hyJSON) else { return }
        do { data = try JSONDecoder().decode(HyData.self, from: d) } catch { self.error = "결과 파일 읽기 실패: \(error)" }
    }

    func check(reset: Bool = false) {
        guard running == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: hyPython) else {
            error = "~/.hywep_check 설치가 안 돼 있어. install_hywep.sh를 먼저 실행해줘."
            return
        }
        running = Date()
        error = nil
        Task {
            let r = await Shell.run(hyPython, [hyScript, reset ? "--reset" : "--force", "--no-popup"])
            running = nil
            if r.code != 0 { error = "확인 실패\n" + tail(r.err) }
            load()
        }
    }
}

// MARK: - 뷰

struct HyContentView: View {
    @EnvironmentObject var store: HyStore
    @State private var query = ""
    @State private var onlyNew = false
    @State private var hideClosed = true
    @State private var selection = Set<Posting.ID>()
    @State private var sortOrder = [KeyPathComparator(\Posting.jidNum, order: .reverse)]

    var rows: [Posting] {
        guard let d = store.data else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return d.rows.filter { r in
            (!onlyNew || r.is_new) && (!hideClosed || r.daysLeft >= 0) &&
                (q.isEmpty || [r.comp, r.dept, r.major, r.loc, r.cat, r.type, r.sched].contains { $0.lowercased().contains(q) })
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = store.error { ErrorBanner(message: e) { store.error = nil } }
            Divider()
            if store.data == nil { empty } else { table }
        }
        .frame(minWidth: 900, minHeight: 500)
        .searchable(text: $query, placement: .toolbar, prompt: "기관·부서·전공·지역 검색 (예: 자동차, 로봇)")
        .onAppear { store.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if store.running == nil { store.load() }
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("HY-WEP 접수중 공고").font(.title2.bold())
                    if let d = store.data, d.new_count > 0 {
                        Text("새 공고 \(d.new_count)").font(.callout.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(.orange, in: Capsule())
                    }
                }
                if let d = store.data, let t = DateUtil.parse(d.checked_at) {
                    Text("총 \(d.total)건 · 표시 \(rows.count)건 · 마지막 확인 \(DateUtil.label(t)) (\(DateUtil.relative(t)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("새 공고만", isOn: $onlyNew).toggleStyle(.checkbox)
            Toggle("마감 지난 것 숨기기", isOn: $hideClosed).toggleStyle(.checkbox)
            if let s = store.running { RunningIndicator(since: s, message: "확인 중…") }
            Button { store.check() } label: { Label("지금 확인", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .disabled(store.running != nil)
            Button { openURL(store.data?.list_url ?? "https://hywep.hanyang.ac.kr/compjoinsearch/list.do") } label: {
                Label("HY-WEP 열기", systemImage: "safari")
            }
            SettingsLink { Image(systemName: "gearshape") }.help("설정")
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
            TableColumn("발견", value: \.found) { r in
                if r.is_new {
                    Text("NEW").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.orange, in: Capsule())
                } else {
                    Text(r.foundLabel).foregroundStyle(.secondary)
                }
            }.width(min: 44, ideal: 52, max: 70)
            TableColumn("기관", value: \.comp) { r in
                Text(r.comp).fontWeight(.semibold).help(r.comp)
            }.width(min: 120, ideal: 170)
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
            TableColumn("모집전공", value: \.major) { r in
                Text(r.major).foregroundStyle(.secondary).help(r.major)
            }.width(min: 100, ideal: 220)
            TableColumn("모집/지원", value: \.quota) { r in Text("\(r.quota) / \(r.applied)").monospacedDigit() }
                .width(min: 50, ideal: 64)
            TableColumn("소재지", value: \.loc).width(min: 60, ideal: 90)
            TableColumn("학기·분류", value: \.sched) { r in
                Text("\(r.shortSched) · \(r.cat)").foregroundStyle(.secondary).help("\(r.sched)\n\(r.cat) · \(r.type)")
            }.width(min: 90, ideal: 160)
        }
        .contextMenu(forSelectionType: Posting.ID.self) { ids in
            if let r = posting(ids) {
                if !r.home.isEmpty { Button("기관 홈페이지 열기") { openURL(r.home) } }
                Button("HY-WEP에서 찾기 (기관명 복사됨)") { copy(r.comp); openURL(store.data?.list_url ?? "") }
                Button("기관명 복사") { copy(r.comp) }
            }
        } primaryAction: { ids in
            // 더블클릭: 홈페이지가 있으면 홈페이지, 없으면 HY-WEP
            if let r = posting(ids) {
                if r.home.isEmpty { copy(r.comp); openURL(store.data?.list_url ?? "") } else { openURL(r.home) }
            }
        }
    }

    func posting(_ ids: Set<Posting.ID>) -> Posting? {
        guard let id = ids.first else { return nil }
        return store.data?.rows.first { $0.id == id }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct HySettingsView: View {
    @EnvironmentObject var store: HyStore
    @State private var confirmReset = false

    var body: some View {
        Form {
            CredentialSection(title: "한양 포털 계정", idService: "hyu-portal-id", pwService: "hyu-portal-pw")

            AutoRunSection(agent: hyAgent, description: "매일 05시 이후 맥을 처음 깨울 때 1번 확인하고, 새 공고가 있으면 팝업")

            Section {
                Button("기준 목록 초기화…", role: .destructive) { confirmReset = true }
                    .disabled(store.running != nil)
                Text("지금 접수중인 공고를 새 기준으로 다시 저장해. 이후엔 그 뒤로 올라온 공고만 NEW로 표시돼.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("기준 목록") }

            Section {
                Button("오류 로그 열기") { openFile(hyDir + "/error.log", textEdit: true) }
                Button("HTML 리포트 열기") { openFile(hyDir + "/latest.html") }
                Button("데이터 폴더 열기") { openFile(hyDir) }
            } header: { Text("기타") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .confirmationDialog("기준 목록을 초기화할까?", isPresented: $confirmReset) {
            Button("초기화", role: .destructive) { store.check(reset: true) }
        } message: {
            Text("지금까지 본 공고 기록(seen.json)이 지워지고 현재 공고로 다시 만들어져.")
        }
    }
}

@main
struct HywepCheckerApp: App {
    @NSApplicationDelegateAdaptor(QuitOnCloseDelegate.self) var delegate
    @StateObject private var store = HyStore()

    var body: some Scene {
        Window("HY-WEP 체커", id: "main") {
            HyContentView().environmentObject(store)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            HySettingsView().environmentObject(store)
        }
    }
}
