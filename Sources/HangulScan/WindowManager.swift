import SwiftUI
import AppKit
import PDFKit

/// 여러 문서를 탭으로: 창(탭)마다 ViewerModel 하나. 파일 열기 요청을 알맞은 탭으로 보낸다.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private final class Box {
        weak var model: ViewerModel?
        let created = Date()
        init(_ m: ViewerModel) { model = m }
    }
    private var boxes: [Box] = []
    private var pendingURLs: [[URL]] = []
    /// 창이 하나도 없을 때 메뉴가 가리킬 빈 모델 (아무 문서도 없음)
    let placeholder = ViewerModel()
    var openWindow: OpenWindowAction?

    var models: [ViewerModel] { boxes.compactMap(\.model) }

    func register(_ m: ViewerModel) {
        boxes.removeAll { $0.model == nil || $0.model === m }
        boxes.append(Box(m))
        // 사용자가 '새 탭'으로 연 탭인지 기록 (그런 빈 탭은 정리하지 않음)
        if userTabRequests > 0 { userTabRequests -= 1; m.userCreatedTab = true }
        // 파일 열기 요청 직후 늦게 생긴 빈 창(앱이 켜지는 중에 흔함) 정리
        if Date().timeIntervalSince(lastExternalOpen) < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.closeStrayBlankWindows() }
        }
    }

    /// 앞에 있는 창의 모델
    var frontModel: ViewerModel? {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, let m = models.first(where: { $0.window === w }) { return m }
        return models.last
    }

    /// Finder·Dock에서 들어온 파일. 화면 틀(SwiftUI)이 열기 요청마다 빈 창을 하나씩 만들므로
    /// 잠시 기다렸다가 그 창을 쓰거나(필요할 때) 닫는다.
    private var lastExternalOpen = Date.distantPast

    func openExternal(_ urls: [URL]) {
        lastExternalOpen = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let fresh = self.boxes.filter { Date().timeIntervalSince($0.created) < 2 }.compactMap(\.model)
                .filter(\.isBlank)
            self.open(urls, preferring: fresh.first)
            self.closeStrayBlankWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.closeStrayBlankWindows() }
        }
    }

    /// 사용자가 연 탭이 아닌 빈 창은, 문서가 열린 다른 창이 있으면 닫는다
    private func closeStrayBlankWindows() {
        guard models.contains(where: { $0.document != nil }) else { return }
        for m in models where m.isBlank && !m.userCreatedTab {
            m.window?.close()
        }
    }

    /// 파일 열기: 이미 열린 문서면 그 탭으로, 빈 탭이 있으면 거기, 아니면 새 탭
    func open(_ urls: [URL], preferring fresh: ViewerModel? = nil) {
        guard !urls.isEmpty else { return }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let others = urls.filter { $0.pathExtension.lowercased() != "pdf" }
        // 사진은 지금 보고 있는 탭에서 스캔 검토 (방금 생긴 빈 창이 아니라)
        if !others.isEmpty {
            let target = models.last(where: { $0 !== fresh && $0.window?.isVisible == true }) ?? fresh ?? models.first
            target?.handle(urls: others)
            target?.window?.makeKeyAndOrderFront(nil)
        }
        for pdf in pdfs { openInTab(pdf, fresh: fresh) }
    }

    private func openInTab(_ url: URL, fresh: ViewerModel? = nil) {
        // 이미 열려 있으면 그 탭을 앞으로
        if let m = models.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            m.window?.makeKeyAndOrderFront(nil)
            return
        }
        let isEmpty = { (m: ViewerModel) in m.isBlank }
        // 사용자가 연 빈 탭(앞쪽) → 그 밖의 빈 탭 → 방금 생긴 빈 창 순서로
        if let empty = [frontModel].compactMap({ $0 }).first(where: { isEmpty($0) && $0 !== fresh })
            ?? models.first(where: { isEmpty($0) && $0 !== fresh })
            ?? fresh.flatMap({ isEmpty($0) ? $0 : nil }) {
            empty.open(url: url)
            empty.window?.makeKeyAndOrderFront(nil)
            return
        }
        pendingURLs.append([url])
        newTab()
    }

    private var userTabRequests = 0

    func newTab(byUser: Bool = false) {
        if byUser { userTabRequests += 1 }
        // 첫 창이 아직 안 떴으면(앱이 켜지는 중) 그 창이 대기 중인 파일을 가져감
        openWindow?(id: "main")
    }

    /// 새 탭이 처음 나타날 때 열 파일
    func takePending() -> [URL]? { pendingURLs.isEmpty ? nil : pendingURLs.removeFirst() }

    var hasUnsaved: [ViewerModel] { models.filter { $0.isDirty && $0.document != nil } }
}

/// 창을 잡아 탭 설정을 하고, 모델에 창을 알려 준다
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onWindow(w) } }
    }
}

/// 탭 하나의 화면: 자기 모델을 갖고, 메뉴가 앞에 있는 탭의 모델을 쓰도록 알림
struct DocumentWindow: View {
    @StateObject private var model = ViewerModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedSceneObject(model)
            // 이미 열린 창이 바깥 열기 요청을 받도록 → 화면 틀이 새 창을 따로 만들지 않음 (열기는 WindowManager가 처리)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .frame(minWidth: 1000, minHeight: 660)
            .background(WindowAccessor { w in
                guard model.window !== w else { return }
                model.window = w
                w.isRestorable = false       // 지난번 빈 창을 되살리지 않음 (문서는 '최근 문서'로)
                // 닫을 때 저장 확인
                if !(w.delegate is WindowCloseGuard) {
                    let guardDelegate = WindowCloseGuard(original: w.delegate, model: model)
                    model.closeGuard = guardDelegate
                    w.delegate = guardDelegate
                }
                w.tabbingIdentifier = "HangulScanDocument"
                w.tabbingMode = .preferred
                // 이미 열린 창이 있으면 그 창의 탭으로 붙임
                if let host = WindowManager.shared.models.compactMap(\.window)
                    .first(where: { $0 !== w && $0.isVisible && $0.tabbingIdentifier == w.tabbingIdentifier }),
                   !(host.tabbedWindows ?? []).contains(w) {
                    host.addTabbedWindow(w, ordered: .above)
                    w.makeKeyAndOrderFront(nil)
                }
            })
            // 창·탭 제목을 문서 이름에 맞춤 (앱이 켜지는 중에 연 문서도 확실히 반영)
            .onChange(of: model.title, initial: true) { _, t in model.window?.title = t }
            .onChange(of: model.window != nil) { _, _ in model.window?.title = model.title }
            .onAppear {
                // 탭으로 붙는 과정에서 사이드바가 접히는 것을 바로잡음
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !model.focusMode { model.columnVisibility = .all }
                }
                WindowManager.shared.openWindow = openWindow
                WindowManager.shared.register(model)
                if let urls = WindowManager.shared.takePending() {
                    DispatchQueue.main.async { model.handle(urls: urls) }
                }
            }
    }
}

// MARK: - 최근 문서

enum RecentDocuments {
    static var urls: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func clear() { NSDocumentController.shared.clearRecentDocuments(nil) }

    /// 첫 쪽 미리보기 (작게)
    static func thumbnail(_ url: URL) -> NSImage? {
        guard let doc = PDFDocument(url: url), !doc.isLocked, let p = doc.page(at: 0) else { return nil }
        return p.thumbnail(of: NSSize(width: 180, height: 240), for: .cropBox)
    }
}

// MARK: - 탭·창을 닫을 때 저장 확인

/// 화면 틀(SwiftUI)이 쓰는 창 관리자를 그대로 두고, '닫기' 직전 확인만 끼워 넣는 대리자
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var model: ViewerModel?

    init(original: NSWindowDelegate?, model: ViewerModel) {
        self.original = original
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let m = model, m.isDirty, m.document != nil {
            let alert = NSAlert()
            alert.messageText = "‘\(m.title.replacingOccurrences(of: " — 편집됨", with: ""))’의 변경 내용을 저장하시겠습니까?"
            alert.informativeText = "저장하지 않으면 OCR 결과와 편집 내용이 사라집니다."
            alert.addButton(withTitle: "저장")
            alert.addButton(withTitle: "취소")
            alert.addButton(withTitle: "저장 안 함")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                m.save()
                if m.isDirty { return false }        // 저장 창에서 취소함
            case .alertSecondButtonReturn:
                return false
            default:
                break
            }
            SpeechReader.shared.stop()
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    // 나머지 알림은 원래 관리자에게 그대로 넘김
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : nil
    }
}
