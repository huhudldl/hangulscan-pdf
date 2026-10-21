import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 지난번 창 복원 끄기 (빈 창이 되살아나지 않게)
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        FolderWatcher.shared.startIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowManager.shared.openExternal(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        TempStore.cleanUp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = WindowManager.shared.hasUnsaved
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "변경 내용을 저장하시겠습니까?" : "저장하지 않은 문서가 \(unsaved.count)개 있습니다."
        alert.informativeText = "저장하지 않으면 OCR 결과와 편집 내용이 사라집니다."
        alert.addButton(withTitle: unsaved.count == 1 ? "저장" : "하나씩 저장")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "저장 안 함")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for m in unsaved {
                m.window?.makeKeyAndOrderFront(nil)
                m.save()
                if m.isDirty { return .terminateCancel }     // 저장 창에서 취소함
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateCancel
        default:
            return .terminateNow
        }
    }
}

struct HangulScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("한글스캔 PDF", id: "main") {
            DocumentWindow()
        }
        .defaultSize(width: 1320, height: 880)
        .commands { AppCommands() }
    }
}

struct AppCommands: Commands {
    /// 앞에 있는 탭의 문서 (탭이 없으면 빈 모델)
    @FocusedObject private var focused: ViewerModel?
    private var model: ViewerModel { focused ?? WindowManager.shared.placeholder }
    private func bind(_ kp: ReferenceWritableKeyPath<ViewerModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: kp] }, set: { model[keyPath: kp] = $0 })
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 탭") { WindowManager.shared.newTab(byUser: true) }.keyboardShortcut("t")
            Button("열기…") { model.openPanel() }.keyboardShortcut("o")
            Menu("최근 문서") {
                ForEach(RecentDocuments.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { WindowManager.shared.open([url]) }
                }
                Divider()
                Button("목록 지우기") { RecentDocuments.clear() }
            }
            Divider()
            Button("카메라로 스캔…") { model.showCamera = true }.keyboardShortcut("k")
            Button("스캐너로 스캔…") { model.showScanner = true }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("이미지에서 스캔 가져오기…") { model.importImagesPanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("닫기") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            Button("저장") { model.save() }.keyboardShortcut("s").disabled(model.document == nil)
            Button("다른 이름으로 저장…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.document == nil)
            Button("용량 줄이기…") { model.showCompress = true }.disabled(model.document == nil)
            Divider()
            Button(model.isPasswordProtected ? "암호 바꾸기…" : "암호 설정…") { model.setPassword() }
                .disabled(model.document == nil)
            Button("암호 해제") { model.removePassword() }
                .disabled(!model.isPasswordProtected)
            Divider()
            Menu("내보내기") {
                Button("텍스트 (줄 단위)…") { model.exportText() }
                Button("문단 텍스트…") { model.exportParagraphText() }
                Button("표 → 엑셀(CSV)…") { model.exportTables() }
            }
            .disabled(model.document == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("인쇄…") { model.printDocument() }.keyboardShortcut("p").disabled(model.document == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("다음 찾기") { model.findNext() }.keyboardShortcut("g")
            Button("이전 찾기") { model.findPrevious() }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("확대") { model.zoomIn() }.keyboardShortcut("+")
            Button("축소") { model.zoomOut() }.keyboardShortcut("-")
            Button("실제 크기") { model.actualSize() }.keyboardShortcut("0")
            Button("폭에 맞추기") { model.fitWidth() }.keyboardShortcut("9")
            Divider()
            Button("다음 페이지") { model.nextPage() }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("이전 페이지") { model.previousPage() }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button(model.focusMode ? "메뉴 모두 보이기" : "메뉴 모두 숨기기") { model.toggleFocusMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Toggle("도구 막대", isOn: bind(\.showToolbar)).keyboardShortcut("t", modifiers: [.command, .option])
            Button(model.columnVisibility == .detailOnly ? "사이드바 보이기" : "사이드바 숨기기") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle("도구 패널", isOn: bind(\.showTools)).keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("상태 표시줄", isOn: bind(\.showStatusBar))
        }
        CommandMenu("페이지") {
            Button("페이지 정리…") { model.showOrganizer = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.document == nil)
            Divider()
            Button("현재 페이지 삭제") { model.deleteCurrentPage() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.document == nil || model.pageCount < 2)
            Divider()
            Button("문서 합치기 (끝에 이어 붙이기)…") { model.mergePanel(afterCurrentPage: false) }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(model.document == nil)
            Button("현재 페이지 뒤에 PDF 삽입…") { model.mergePanel(afterCurrentPage: true) }
                .disabled(model.document == nil)
            Divider()
            Button("오른쪽으로 회전") { model.rotateCurrentPage(clockwise: true) }.keyboardShortcut("r")
                .disabled(model.document == nil)
            Button("왼쪽으로 회전") { model.rotateCurrentPage(clockwise: false) }.keyboardShortcut("l")
                .disabled(model.document == nil)
        }
        CommandMenu("OCR") {
            Button("현재 페이지 한국어 OCR") { model.runOCR(currentPageOnly: true) }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(model.document == nil || model.isProcessing)
            Button("전체 문서 한국어 OCR") { model.runOCR(currentPageOnly: false) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.document == nil || model.isProcessing)
            Button("표를 엑셀(CSV)로 내보내기…") { model.exportTables() }
                .disabled(model.document == nil || model.isProcessing)
            Button("문단 텍스트로 내보내기…") { model.exportParagraphText() }
                .disabled(model.document == nil || model.isProcessing)
            Divider()
            Button("인식 결과 교정…") { model.showCorrection = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.document == nil)
            Divider()
            Button("선택한 텍스트 강조") { model.highlightSelection() }.keyboardShortcut("h", modifiers: [.command, .control])
            Button(model.showAnnotationBar ? "주석 도구 닫기" : "주석 도구 열기") {
                model.showAnnotationBar.toggle()
                if !model.showAnnotationBar { model.annotTool = .select }
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(model.document == nil)
            Button("서명 만들기…") { model.showSignaturePad = true }
        }
    }
}
