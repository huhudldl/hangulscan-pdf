import SwiftUI
import PDFKit
import CoreImage
import UniformTypeIdentifiers

final class ViewerModel: ObservableObject {
    /// 이 문서가 표시되는 창(탭)
    weak var window: NSWindow?
    /// 창 닫기 확인 대리자 (창은 대리자를 약하게 잡으므로 여기서 붙잡아 둠)
    var closeGuard: NSObject?
    /// 사용자가 '새 탭'으로 직접 연 탭 (비어 있어도 자동으로 닫지 않음)
    var userCreatedTab = false

    let pdfView: AnnotatingPDFView = {
        let v = AnnotatingPDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        v.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        }
        return v
    }()

    // 문서
    @Published private(set) var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var currentPage = 0
    @Published var pageCount = 0
    @Published var zoomPercent = 100
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous {
        didSet { pdfView.displayMode = displayMode }
    }
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    @Published var showTools = true
    @Published var showToolbar = true
    @Published var showStatusBar = true
    @Published private(set) var focusMode = false
    private var savedLayout: (NavigationSplitViewVisibility, Bool, Bool, Bool)?
    @Published var outline: [OutlineItem] = []
    private var needsSaveAs = false
    /// 저장할 때 걸 암호 (암호 PDF를 열었거나 '암호 설정'을 했을 때)
    @Published private(set) var documentPassword: String?
    private var suggestedName = "문서.pdf"

    // 검색
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = -1

    // OCR
    @Published var settings = OCRSettings.load() { didSet { if settings != oldValue { settings.save() } } }
    @Published var isProcessing = false
    @Published var progress = 0.0
    @Published var progressMessage = ""
    @Published var statusMessage = ""
    @Published var pageTexts: [Int: String] = [:]
    @Published var pageReports: [Int: ProcessReport] = [:]
    /// 쪽별 OCR 결과 줄(위치·확신도 포함) — 교정 화면에서 사용
    @Published var pageLines: [Int: [OCRLine]] = [:]
    @Published var showOrganizer = false
    @Published var showCorrection = false
    @Published var showCompress = false
    // 주석
    @Published var showAnnotationBar = false
    @Published var showSignaturePad = false
    @Published var annotTool: AnnotTool = .select { didSet { pdfView.tool = annotTool } }
    @Published var annotColor: Color = .red { didSet { pdfView.color = NSColor(annotColor); annotColorChosen = true } }
    /// 사용자가 색을 직접 골랐는지 (안 골랐으면 형광펜은 노란색)
    var annotColorChosen = false
    @Published var annotLineWidth: Double = 2 { didSet { pdfView.lineWidth = annotLineWidth } }
    private var cancelToken: CancelToken?

    // 스캔
    @Published var scannedPages: [ScanPage] = []
    @Published var pendingScanCount = 0
    @Published var showCamera = false
    @Published var showReview = false
    @Published var showScanner = false
    @Published var errorMessage: String?
    private let scanQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = Parallel.workerCount
        q.qualityOfService = .userInitiated
        return q
    }()
    private var scanSequence = 0
    private var nextScanToShow = 0
    private var finishedScans: [Int: [ScanPage]] = [:]

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.syncPage()
        })
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.zoomPercent = Int((self.pdfView.scaleFactor * 100).rounded())
        })
        observers.append(nc.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { _ in })
        pdfView.color = NSColor(annotColor)
        setupAnnotationHandlers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 아무것도 하지 않은 빈 탭인가 (문서·스캔·보정 중인 사진·열린 시트 없음)
    var isBlank: Bool {
        document == nil && scannedPages.isEmpty && pendingScanCount == 0 && !showReview && !showCamera && !showScanner
    }

    var title: String {
        guard document != nil else { return "한글스캔 PDF" }
        let name = fileURL?.lastPathComponent ?? suggestedName
        return isDirty ? "\(name) — 편집됨" : name
    }

    var currentPageText: String {
        if let t = pageTexts[currentPage], !t.isEmpty { return t }
        guard let page = document?.page(at: currentPage) else { return "" }
        let key = ObjectIdentifier(page)
        if textProbeCache[key] == nil { textProbeCache[key] = PDFTextProbe.hasText(page) }
        return textProbeCache[key] == true ? (page.string ?? "") : ""
    }
    private var textProbeCache: [ObjectIdentifier: Bool] = [:]

    // MARK: - 열기 / 저장

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "PDF 또는 스캔 이미지를 선택하세요"
        guard panel.runModal() == .OK else { return }
        // 이미 문서가 열려 있으면 PDF는 새 탭으로
        if document != nil { WindowManager.shared.open(panel.urls) } else { handle(urls: panel.urls) }
    }

    func importImagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "스캔하거나 촬영한 문서 사진을 선택하세요 (자동 수평 보정 + 한국어 OCR)"
        guard panel.runModal() == .OK else { return }
        handle(urls: panel.urls)
    }

    func handle(urls: [URL], askMerge: Bool = false) {
        let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !pdfs.isEmpty {
            if document != nil && askMerge {
                let alert = NSAlert()
                alert.messageText = "PDF \(pdfs.count)개를 어떻게 열까요?"
                alert.informativeText = "현재 문서에 합치거나, 새로 열 수 있습니다."
                alert.addButton(withTitle: "현재 문서 끝에 합치기")
                alert.addButton(withTitle: "새로 열기")
                alert.addButton(withTitle: "취소")
                switch alert.runModal() {
                case .alertFirstButtonReturn: insertDocuments(pdfs, at: pageCount)
                case .alertSecondButtonReturn: WindowManager.shared.open(pdfs)
                default: break
                }
            } else {
                open(url: pdfs[0])
                if pdfs.count > 1 { WindowManager.shared.open(Array(pdfs.dropFirst())) }
            }
        }
        if !images.isEmpty {
            importScans(images.map { ScanInput.file($0) })
            showReview = true
        }
    }

    func open(url: URL) {
        guard let doc = PDFDocument(url: url) else {
            errorMessage = "PDF 파일을 열 수 없습니다: \(url.lastPathComponent)"
            return
        }
        var password: String?
        if doc.isLocked {
            guard let pw = Self.unlock(doc, name: url.lastPathComponent) else { return }
            password = pw
        }
        setDocument(doc, url: url, dirty: false)
        documentPassword = password
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func setDocument(_ doc: PDFDocument, url: URL?, dirty: Bool, suggestedName: String? = nil, keepPage: Int = 0) {
        if url != nil { documentPassword = nil }
        document = doc
        fileURL = url
        isDirty = dirty
        needsSaveAs = url == nil
        if let s = suggestedName { self.suggestedName = s }
        pdfView.document = doc
        pageCount = doc.pageCount
        if keepPage > 0, let p = doc.page(at: min(keepPage, doc.pageCount - 1)) { pdfView.go(to: p) }
        if url != nil { pageTexts = [:]; pageReports = [:]; pageLines = [:] }
        clearSearch()
        buildOutline()
        syncPage()
    }

    func save() {
        guard let doc = document else { return }
        if let url = fileURL, !needsSaveAs { write(doc, to: url) } else { saveAs() }
    }

    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(doc, to: url)
    }

    private func write(_ doc: PDFDocument, to url: URL) {
        let ok: Bool
        if let pw = documentPassword {
            ok = doc.write(to: url, withOptions: [.userPasswordOption: pw, .ownerPasswordOption: pw])
        } else if doc.isEncrypted {
            ok = Self.unencryptedCopy(doc).write(to: url)       // 암호를 해제한 경우: 잠금 없는 사본으로 저장
        } else {
            ok = doc.write(to: url)
        }
        if ok {
            fileURL = url
            isDirty = false
            needsSaveAs = false
            statusMessage = "저장했습니다: \(url.lastPathComponent)" + (documentPassword != nil ? " (암호 걸림)" : "")
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } else {
            errorMessage = "저장에 실패했습니다."
        }
    }

    func exportText() {
        guard let doc = document else { return }
        var out = ""
        for i in 0..<doc.pageCount {
            let page = doc.page(at: i)
            let t = pageTexts[i] ?? (page.map { PDFTextProbe.hasText($0) ? ($0.string ?? "") : "" } ?? "")
            out += "─── \(i + 1)쪽 ───\n\(t)\n\n"
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = ((fileURL?.deletingPathExtension().lastPathComponent) ?? "OCR") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try out.write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = "텍스트 저장 실패: \(error.localizedDescription)" }
    }

    // MARK: - 암호

    /// 잠긴 PDF의 암호를 물어 연다. 성공하면 암호, 취소하면 nil
    static func unlock(_ doc: PDFDocument, name: String) -> String? {
        var message = "‘\(name)’은(는) 암호로 보호된 PDF입니다. 암호를 입력하세요."
        for _ in 0..<5 {
            guard let pw = askPassword(title: "암호 입력", message: message, confirm: false) else { return nil }
            if doc.unlock(withPassword: pw) { return pw }
            message = "암호가 맞지 않습니다. 다시 입력하세요."
        }
        return nil
    }

    /// 암호 입력 창. confirm이면 두 번 입력받아 같은지 확인
    static func askPassword(title: String, message: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 260, height: 24))
        first.placeholderString = "암호"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        second.placeholderString = "암호 확인"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 54 : 24))
        box.addSubview(first)
        if confirm { box.addSubview(second) }
        alert.accessoryView = box
        alert.window.initialFirstResponder = first
        while alert.runModal() == .alertFirstButtonReturn {
            let pw = first.stringValue
            if pw.isEmpty { alert.informativeText = "암호를 입력하세요."; continue }
            if confirm && pw != second.stringValue { alert.informativeText = "두 암호가 다릅니다. 다시 입력하세요."; continue }
            return pw
        }
        return nil
    }

    /// 쪽만 옮겨 담은 잠금 없는 사본 (작업용 임시 파일·암호 해제 저장에 사용)
    static func unencryptedCopy(_ doc: PDFDocument) -> PDFDocument {
        let out = PDFDocument()
        for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        out.outlineRoot = doc.outlineRoot
        return out
    }

    func setPassword() {
        guard document != nil, let pw = Self.askPassword(title: "암호 설정",
              message: "저장할 때 이 암호를 겁니다. 암호를 잊으면 파일을 열 수 없으니 주의하세요.", confirm: true) else { return }
        documentPassword = pw
        isDirty = true
        statusMessage = "암호를 설정했습니다 — 저장하면 적용됩니다 (⌘S)"
    }

    func removePassword() {
        guard document != nil else { return }
        documentPassword = nil
        isDirty = true
        statusMessage = "암호를 해제했습니다 — 저장하면 암호 없는 파일이 됩니다 (⌘S)"
    }

    var isPasswordProtected: Bool { documentPassword != nil }

    // MARK: - 표·문단 내보내기 (macOS 26 문서 구조 인식)

    /// 지금 문서를 파일로 준비 (저장된 원본 그대로면 그 파일, 편집 중이면 임시 파일)
    func fileForJob() -> URL? { documentFileForJob() }

    /// 용량 줄인 결과를 저장 (지금 문서의 암호 설정도 그대로 적용)
    func saveCompressed(_ file: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(exportBaseName)_작게.pdf"
        guard panel.runModal() == .OK, let url = panel.url, let doc = PDFDocument(url: file) else { return }
        let ok = documentPassword.map { doc.write(to: url, withOptions: [.userPasswordOption: $0, .ownerPasswordOption: $0]) }
            ?? doc.write(to: url)
        if ok { statusMessage = "용량을 줄여 저장했습니다: \(url.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { errorMessage = "저장에 실패했습니다." }
    }

    private func documentFileForJob() -> URL? {
        guard let doc = document else { return nil }
        if let u = fileURL, !isDirty, !doc.isEncrypted { return u }
        let tmp = TempStore.newURL("pdf")
        let ok = doc.isEncrypted ? Self.unencryptedCopy(doc).write(to: tmp) : doc.write(to: tmp)
        return ok ? tmp : nil
    }

    private func runStructure(_ done: @escaping ([Int: StructureJob.PageResult]) -> Void) {
        guard !isProcessing, let input = documentFileForJob() else { return }
        let languages = settings.languages
        let token = CancelToken()
        cancelToken = token
        isProcessing = true
        progress = 0
        progressMessage = "표·문단 찾는 중…"
        Task.detached(priority: .userInitiated) {
            do {
                let r = try await StructureJob.run(pdf: input, languages: languages, cancel: token) { f, m in
                    DispatchQueue.main.async { self.progress = f; self.progressMessage = m }
                }
                await MainActor.run { self.isProcessing = false; done(r) }
            } catch is CancellationError {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "취소했습니다" }
            } catch {
                await MainActor.run { self.isProcessing = false; self.errorMessage = "표·문단 인식 실패: \(error.localizedDescription)" }
            }
        }
    }

    private var exportBaseName: String { fileURL?.deletingPathExtension().lastPathComponent ?? (suggestedName as NSString).deletingPathExtension }

    /// 문서의 모든 표를 엑셀에서 바로 열리는 CSV로 (표가 여러 개면 폴더에 표마다 한 파일)
    func exportTables() {
        runStructure { pages in
            let tables = pages.sorted { $0.key < $1.key }.flatMap { i, r in r.tables.map { (page: i, rows: $0) } }
            guard !tables.isEmpty else {
                self.errorMessage = "이 문서에서 표를 찾지 못했습니다."
                return
            }
            if tables.count == 1 {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.commaSeparatedText]
                panel.nameFieldStringValue = "\(self.exportBaseName)_표.csv"
                panel.message = "엑셀·Numbers에서 바로 열 수 있는 CSV로 저장합니다"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try StructureJob.csv(tables[0].rows).write(to: url)
                    self.statusMessage = "표 1개를 저장했습니다: \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { self.errorMessage = "저장 실패: \(error.localizedDescription)" }
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "이 폴더에 저장"
                panel.message = "표 \(tables.count)개를 표마다 CSV 파일로 저장할 폴더를 고르세요"
                guard panel.runModal() == .OK, let dir = panel.url else { return }
                var saved: [URL] = []
                for (k, t) in tables.enumerated() {
                    let url = FolderWatcher.unique(dir.appendingPathComponent("\(self.exportBaseName)_표\(k + 1)_\(t.page + 1)쪽.csv"))
                    if (try? StructureJob.csv(t.rows).write(to: url)) != nil { saved.append(url) }
                }
                self.statusMessage = "표 \(saved.count)개를 저장했습니다"
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
        }
    }

    /// 줄바꿈이 아닌 문단 단위로 정리된 텍스트 (표는 제자리에 칸 구분으로)
    func exportParagraphText() {
        runStructure { pages in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(self.exportBaseName)_문단.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try StructureJob.paragraphText(pages).write(to: url, atomically: true, encoding: .utf8)
                self.statusMessage = "문단 텍스트를 저장했습니다: \(url.lastPathComponent)"
            } catch { self.errorMessage = "저장 실패: \(error.localizedDescription)" }
        }
    }

    func printDocument() {
        guard document != nil else { return }
        pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
    }

    // MARK: - 탐색 / 보기

    private func syncPage() {
        guard let doc = document, let page = pdfView.currentPage else { return }
        currentPage = doc.index(for: page)
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    func goTo(page index: Int) {
        guard let doc = document, doc.pageCount > 0 else { return }
        let i = max(0, min(index, doc.pageCount - 1))
        if let p = doc.page(at: i) { pdfView.go(to: p) }
    }

    func nextPage() { pdfView.goToNextPage(nil) }
    func previousPage() { pdfView.goToPreviousPage(nil) }
    func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    func fitWidth() { pdfView.autoScales = true }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    func setZoom(_ percent: Int) { pdfView.autoScales = false; pdfView.scaleFactor = CGFloat(percent) / 100 }

    func rotateCurrentPage(clockwise: Bool) {
        guard let page = pdfView.currentPage else { return }
        page.rotation = (page.rotation + (clockwise ? 90 : -90) + 360) % 360
        isDirty = true
        pdfView.layoutDocumentView()
    }

    func highlightSelection() {
        guard let sel = pdfView.currentSelection else {
            statusMessage = "강조할 텍스트를 먼저 드래그해서 선택하세요"
            return
        }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.5)
                page.addAnnotation(a)
            }
        }
        pdfView.clearSelection()
        isDirty = true
    }

    // MARK: - 메뉴 숨기기 / 다시 불러오기

    /// 도구 막대·사이드바·도구 패널·상태 표시줄을 한 번에 숨기거나 되살린다.
    func toggleFocusMode() {
        if focusMode, let s = savedLayout {
            columnVisibility = s.0; showTools = s.1; showToolbar = s.2; showStatusBar = s.3
            focusMode = false
            savedLayout = nil
        } else {
            savedLayout = (columnVisibility, showTools, showToolbar, showStatusBar)
            columnVisibility = .detailOnly; showTools = false; showToolbar = false; showStatusBar = false
            focusMode = true
        }
    }

    func toggleSidebar() { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }

    // MARK: - 페이지 편집 (합치기 / 삭제)

    private var undoManager: UndoManager? { pdfView.window?.undoManager ?? pdfView.undoManager }

    /// 다른 PDF를 골라 현재 문서에 합친다.
    func mergePanel(afterCurrentPage: Bool) {
        guard document != nil else { openPanel(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = afterCurrentPage
            ? "\(currentPage + 1)쪽 뒤에 끼워 넣을 PDF를 선택하세요 (여러 개 선택 가능)"
            : "문서 끝에 이어 붙일 PDF를 선택하세요 (여러 개 선택 가능, 선택한 순서대로)"
        guard panel.runModal() == .OK else { return }
        insertDocuments(panel.urls, at: afterCurrentPage ? currentPage + 1 : pageCount)
    }

    func insertDocuments(_ urls: [URL], at index: Int) {
        guard let doc = document else { return }
        var pages: [PDFPage] = []
        var names: [String] = []
        for url in urls {
            guard let other = PDFDocument(url: url) else {
                errorMessage = "합칠 수 없는 PDF입니다: \(url.lastPathComponent)"
                continue
            }
            if other.isLocked && Self.unlock(other, name: url.lastPathComponent) == nil { continue }
            for i in 0..<other.pageCount {
                if let p = other.page(at: i)?.copy() as? PDFPage { pages.append(p) }
            }
            names.append(url.lastPathComponent)
        }
        guard !pages.isEmpty else { return }
        insert(pages, at: min(index, doc.pageCount), texts: [], reports: [])
        undoManager?.setActionName("문서 합치기")
        statusMessage = "\(names.joined(separator: ", ")) — \(pages.count)쪽을 합쳤습니다 (⌘Z로 되돌리기)"
    }

    /// 현재 보고 있는 한 쪽을 삭제 (⌘Z로 되돌릴 수 있음)
    func deleteCurrentPage() {
        guard let doc = document else { return }
        guard doc.pageCount > 1 else {
            errorMessage = "문서에 남은 마지막 한 쪽은 삭제할 수 없습니다."
            return
        }
        let i = currentPage
        remove(range: i..<(i + 1))
        undoManager?.setActionName("페이지 삭제")
        statusMessage = "\(i + 1)쪽을 삭제했습니다 (⌘Z로 되돌리기)"
    }

    private func insert(_ pages: [PDFPage], at index: Int, texts: [String?], reports: [ProcessReport?], lines: [[OCRLine]?] = []) {
        guard let doc = document else { return }
        shiftPageData(from: index, by: pages.count)
        for (k, p) in pages.enumerated() {
            doc.insert(p, at: index + k)
            if k < texts.count, let t = texts[k] { pageTexts[index + k] = t }
            if k < reports.count, let r = reports[k] { pageReports[index + k] = r }
            if k < lines.count, let l = lines[k] { pageLines[index + k] = l }
        }
        let range = index..<(index + pages.count)
        undoManager?.registerUndo(withTarget: self) { $0.remove(range: range) }
        pagesChanged(goTo: index)
    }

    private func remove(range: Range<Int>) {
        guard let doc = document else { return }
        var pages: [PDFPage] = [], texts: [String?] = [], reports: [ProcessReport?] = [], lines: [[OCRLine]?] = []
        for i in range {
            guard let p = doc.page(at: range.lowerBound) else { continue }
            pages.append(p)
            texts.append(pageTexts.removeValue(forKey: i))
            reports.append(pageReports.removeValue(forKey: i))
            lines.append(pageLines.removeValue(forKey: i))
            doc.removePage(at: range.lowerBound)
        }
        shiftPageData(from: range.upperBound, by: -range.count)
        let at = range.lowerBound
        undoManager?.registerUndo(withTarget: self) { $0.insert(pages, at: at, texts: texts, reports: reports, lines: lines) }
        pagesChanged(goTo: min(at, doc.pageCount - 1))
    }

    /// 페이지 번호가 바뀐 만큼 OCR 텍스트·보정 기록의 번호도 옮긴다
    private func shiftPageData(from start: Int, by delta: Int) {
        func shift<V>(_ d: [Int: V]) -> [Int: V] {
            Dictionary(uniqueKeysWithValues: d.map { ($0.key >= start ? $0.key + delta : $0.key, $0.value) })
        }
        pageTexts = shift(pageTexts)
        pageReports = shift(pageReports)
        pageLines = shift(pageLines)
    }

    // MARK: - 인식 결과 교정

    /// 이 쪽을 교정할 수 없는 이유 (교정 가능하면 nil)
    func correctionBlocker(_ index: Int) -> String? {
        guard let page = document?.page(at: index) else { return "쪽이 없습니다." }
        if pageLines[index] != nil { return nil }
        switch PDFTextProbe.kind(page) {
        case .visibleText: return "이 쪽은 원래 글자가 들어 있는 문서라 교정할 필요가 없습니다."
        case .none, .ocrLayerOnly: return nil
        }
    }

    /// 확인이 필요한 줄 수 (이번에 인식한 쪽 기준)
    var reviewCount: Int { pageLines.values.reduce(0) { $0 + $1.filter(\.needsReview).count } }

    /// 교정할 줄 목록을 가져온다. 이번에 인식한 쪽은 저장된 결과, 아니면 쪽을 다시 인식(문서는 바꾸지 않음).
    func linesForCorrection(_ index: Int, completion: @escaping ([OCRLine]?) -> Void) {
        if let l = pageLines[index] { completion(l); return }
        guard let page = document?.page(at: index)?.copy() as? PDFPage else { completion(nil); return }
        let languages = settings.languages
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = SearchablePDF.render(page, dpi: 300).flatMap { try? OCREngine.recognize($0, languages: languages) }
            DispatchQueue.main.async { completion(lines) }
        }
    }

    /// 교정한 줄로 쪽의 검색용 글자층을 다시 만든다. 여러 쪽을 한 번에, ⌘Z 한 번으로 되돌림.
    func applyCorrections(_ edits: [Int: [OCRLine]]) {
        guard let doc = document, !edits.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        var done = 0
        for (i, lines) in edits.sorted(by: { $0.key < $1.key }) {
            guard let old = doc.page(at: i), let newPage = rebuildPage(old, lines: lines) else { continue }
            replacePage(at: i, with: newPage, lines: lines, text: OCREngine.layoutText(lines))
            done += 1
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("인식 결과 교정")
        pagesChanged(goTo: edits.keys.min() ?? currentPage)
        statusMessage = "\(done)쪽의 인식 결과를 교정했습니다 — 검색·복사에 바로 반영됩니다 (⌘Z로 되돌리기)"
    }

    /// 쪽 그림은 그대로 두고 보이지 않는 글자층만 새 줄로 바꾼 쪽을 만든다 (주석은 옮겨 붙임)
    private func rebuildPage(_ page: PDFPage, lines: [OCRLine]) -> PDFPage? {
        let annotations = page.annotations
        annotations.forEach { $0.shouldDisplay = false }      // 주석이 그림에 찍히지 않게
        defer { annotations.forEach { $0.shouldDisplay = true } }
        let dpi: CGFloat = 300
        guard let image = SearchablePDF.render(page, dpi: dpi) else { return nil }
        let size = CGSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        let file = TempStore.newURL("pdf")
        guard let writer = SearchablePDF.Writer(url: file) else { return nil }
        writer.addPage(image: image, lines: lines, pageSize: size, jpegQuality: 0.9)
        writer.close()
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
              let one = PDFDocument(data: data), let newPage = one.page(at: 0) else { return nil }
        if page.rotation == 0 {
            for a in annotations { if let c = a.copy() as? PDFAnnotation { newPage.addAnnotation(c) } }
        }
        return newPage
    }

    private func replacePage(at i: Int, with newPage: PDFPage, lines: [OCRLine]?, text: String?) {
        guard let doc = document, let old = doc.page(at: i) else { return }
        let oldLines = pageLines[i], oldText = pageTexts[i]
        doc.removePage(at: i)
        doc.insert(newPage, at: i)
        pageLines[i] = lines
        pageTexts[i] = text
        isDirty = true
        undoManager?.registerUndo(withTarget: self) {
            $0.replacePage(at: i, with: old, lines: oldLines, text: oldText)
            $0.pagesChanged(goTo: i)
        }
    }

    // MARK: - 페이지 정리 (순서·회전·삭제를 한 번에 적용)

    /// 문서의 쪽 구성을 pages 순서로 바꾸고 각 쪽 회전을 rotations로 맞춘다. ⌘Z로 이전 구성 복원.
    func applyPages(_ pages: [PDFPage], rotations: [Int], actionName: String, goTo target: Int = 0) {
        guard let doc = document, !pages.isEmpty else { return }
        let oldPages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        let oldRotations = oldPages.map(\.rotation)
        // 쪽 번호 대신 쪽 객체 기준으로 OCR 데이터를 옮김
        var texts: [ObjectIdentifier: String] = [:], reports: [ObjectIdentifier: ProcessReport] = [:]
        var lines: [ObjectIdentifier: [OCRLine]] = [:]
        for (i, p) in oldPages.enumerated() {
            let k = ObjectIdentifier(p)
            texts[k] = pageTexts[i]; reports[k] = pageReports[i]; lines[k] = pageLines[i]
        }
        while doc.pageCount > 0 { doc.removePage(at: doc.pageCount - 1) }
        for (i, p) in pages.enumerated() {
            if i < rotations.count { p.rotation = rotations[i] }
            doc.insert(p, at: i)
        }
        pageTexts = [:]; pageReports = [:]; pageLines = [:]
        for (i, p) in pages.enumerated() {
            let k = ObjectIdentifier(p)
            pageTexts[i] = texts[k]; pageReports[i] = reports[k]; pageLines[i] = lines[k]
        }
        let back = min(currentPage, oldPages.count - 1)
        undoManager?.registerUndo(withTarget: self) {
            $0.applyPages(oldPages, rotations: oldRotations, actionName: actionName, goTo: back)
        }
        undoManager?.setActionName(actionName)
        pagesChanged(goTo: min(target, pages.count - 1))
    }

    /// 지정한 쪽들만 새 PDF로 저장
    func extractPages(_ pages: [PDFPage], rotations: [Int]) {
        let out = PDFDocument()
        for (i, p) in pages.enumerated() {
            guard let c = p.copy() as? PDFPage else { continue }
            if i < rotations.count { c.rotation = rotations[i] }
            out.insert(c, at: out.pageCount)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "문서"
        panel.nameFieldStringValue = "\(base)_\(pages.count)쪽 추출.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if out.write(to: url) { statusMessage = "\(pages.count)쪽을 따로 저장했습니다: \(url.lastPathComponent)" }
        else { errorMessage = "저장에 실패했습니다." }
    }

    private func pagesChanged(goTo index: Int) {
        guard let doc = document else { return }
        pageCount = doc.pageCount
        isDirty = true
        clearSearch()
        buildOutline()
        // 화면과 썸네일이 바뀐 쪽 구성을 확실히 반영하도록 문서를 다시 연결
        let autoScales = pdfView.autoScales, scale = pdfView.scaleFactor
        pdfView.document = nil
        pdfView.document = doc
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        goTo(page: index)
        syncPage()
    }

    private func buildOutline() {
        guard let doc = document, let root = doc.outlineRoot else { outline = []; return }
        func items(_ node: PDFOutline) -> [OutlineItem] {
            (0..<node.numberOfChildren).compactMap { i in
                guard let c = node.child(at: i) else { return nil }
                let kids = items(c)
                let idx = c.destination?.page.map { doc.index(for: $0) }
                return OutlineItem(title: c.label ?? "제목 없음", pageIndex: idx, children: kids.isEmpty ? nil : kids)
            }
        }
        outline = items(root)
    }

    // MARK: - 검색

    func find() {
        guard let doc = document else { return }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { clearSearch(); return }
        searchResults = doc.findString(q, withOptions: [.caseInsensitive])
        pdfView.highlightedSelections = searchResults.map { s in
            let c = s.copy() as! PDFSelection
            c.color = NSColor.systemOrange.withAlphaComponent(0.45)
            return c
        }
        searchIndex = -1
        if searchResults.isEmpty {
            statusMessage = "'\(q)' 검색 결과 없음 — 스캔 문서라면 먼저 한국어 OCR을 실행하세요"
        } else {
            statusMessage = "'\(q)' \(searchResults.count)건 찾음"
            selectResult(0)
        }
    }

    func selectResult(_ i: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (i + searchResults.count) % searchResults.count
        let sel = searchResults[searchIndex]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
    }

    func findNext() { searchResults.isEmpty ? find() : selectResult(searchIndex + 1) }
    func findPrevious() { selectResult(searchIndex - 1) }

    func clearSearch() {
        searchResults = []
        searchIndex = -1
        pdfView.highlightedSelections = nil
    }

    // MARK: - 한국어 OCR

    func runOCR(currentPageOnly: Bool) {
        guard document != nil, !isProcessing else { return }
        // 저장된 원본이 그대로면 그 파일을, 편집 중이거나 암호가 있으면 임시 파일을 입력으로 사용
        guard let input = documentFileForJob() else { errorMessage = "OCR 준비 중 오류가 났습니다."; return }
        let password = documentPassword
        let output = TempStore.newURL("pdf")
        let pages: Set<Int>? = currentPageOnly ? [currentPage] : nil
        let settings = self.settings
        let token = CancelToken()
        cancelToken = token
        isProcessing = true
        progress = 0
        progressMessage = "준비 중…"
        let keepPage = currentPage
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? "스캔"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try PDFOCRJob.run(input: input, output: output, pages: pages, settings: settings, cancel: token) { f, m in
                    DispatchQueue.main.async { self.progress = f; self.progressMessage = m }
                }
                DispatchQueue.main.async {
                    self.isProcessing = false
                    guard let newDoc = PDFDocument(url: output) else { return }
                    // 책 모드로 쪽이 나뉘면 쪽 번호가 바뀌므로 결과로 통째로 교체
                    let texts = r.texts
                    let reports = r.reports
                    if r.ocrPageCount > 0 {
                        // 원본을 덮어쓰지 않도록 '다른 이름으로 저장' 유도
                        self.setDocument(newDoc, url: nil, dirty: true, suggestedName: "\(baseName)_OCR.pdf", keepPage: keepPage)
                        self.documentPassword = password      // 원본에 암호가 있었으면 저장할 때 그대로 유지
                        self.statusMessage = "한국어 OCR 완료: \(r.ocrPageCount)쪽 인식 — 이제 검색·복사가 가능합니다 (⌘S로 저장)"
                        self.pageTexts = texts
                        self.pageReports = reports
                        self.pageLines = r.lines
                    } else {
                        self.statusMessage = "모든 페이지에 이미 텍스트가 있어 건너뛰었습니다. (설정에서 '텍스트 있는 페이지 건너뛰기'를 끄면 다시 인식)"
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async { self.isProcessing = false; self.statusMessage = "OCR을 취소했습니다" }
            } catch {
                DispatchQueue.main.async { self.isProcessing = false; self.errorMessage = "OCR 실패: \(error.localizedDescription)" }
            }
        }
    }

    func cancelProcessing() { cancelToken?.isCancelled = true }

    // MARK: - 스캔

    /// 촬영/가져온 이미지를 여러 장 동시에 보정(문서 자르기, 방향, 수평)하고,
    /// 결과는 촬영한 순서대로 스캔 목록에 추가. 이미지는 디스크에 저장해 메모리에 쌓지 않음.
    func importScans(_ inputs: [ScanInput]) {
        let options = settings.processing
        pendingScanCount += inputs.count
        for input in inputs {
            let seq = scanSequence
            scanSequence += 1
            scanQueue.addOperation {
                let pages: [ScanPage] = autoreleasepool {
                    let sourceURL: URL?
                    let image: CIImage?
                    switch input {
                    case .file(let url):
                        sourceURL = url
                        image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
                    case .image(let img):
                        sourceURL = TempStore.saveJPEG(img)
                        image = img
                    }
                    guard let sourceURL, let image else { return [] }
                    // 책 모드면 펼친 면 한 장이 두 쪽이 됨
                    return ImageProcessor.processPages(image, options: options, detectDocument: true).compactMap { cg, report in
                        guard let url = TempStore.saveJPEG(cg), let thumb = TempStore.thumbnail(url) else { return nil }
                        return ScanPage(sourceURL: sourceURL, imageURL: url, thumbnail: thumb, report: report)
                    }
                }
                DispatchQueue.main.async {
                    self.finishedScans[seq] = pages
                    self.flushFinishedScans()
                }
            }
        }
    }

    private func flushFinishedScans() {
        while let entry = finishedScans.removeValue(forKey: nextScanToShow) {
            scannedPages.append(contentsOf: entry)
            nextScanToShow += 1
            pendingScanCount -= 1
        }
    }

    func reprocessScans() {
        var seen = Set<URL>()
        let sources = scannedPages.compactMap { seen.insert($0.sourceURL).inserted ? ScanInput.file($0.sourceURL) : nil }
        scannedPages.forEach { try? FileManager.default.removeItem(at: $0.imageURL) }
        scannedPages = []
        importScans(sources)
    }

    func buildPDFFromScans(appendToCurrent: Bool) {
        guard !scannedPages.isEmpty, !isProcessing else { return }
        let files = scannedPages.map(\.imageURL)
        let reports = scannedPages.map(\.report)
        let languages = settings.languages
        let pageSize = settings.pageSize
        let token = CancelToken()
        cancelToken = token
        isProcessing = true
        progress = 0
        showReview = false
        let output = TempStore.newURL("pdf")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try ScanPDFJob.run(imageFiles: files, languages: languages, pageSize: pageSize, output: output, cancel: token) { f, m in
                    DispatchQueue.main.async { self.progress = f; self.progressMessage = m }
                }
                let texts = result.texts
                DispatchQueue.main.async {
                    self.isProcessing = false
                    guard let scanDoc = PDFDocument(url: output) else { return }
                    let stamp = Self.stamp()
                    if appendToCurrent, let doc = self.document {
                        let offset = doc.pageCount
                        for i in 0..<scanDoc.pageCount {
                            if let p = scanDoc.page(at: i) { doc.insert(p, at: doc.pageCount) }
                        }
                        for (i, t) in texts { self.pageTexts[offset + i] = t }
                        for (i, l) in result.lines { self.pageLines[offset + i] = l }
                        for (i, r) in reports.enumerated() { self.pageReports[offset + i] = r }
                        self.pageCount = doc.pageCount
                        self.isDirty = true
                        self.pdfView.layoutDocumentView()
                        self.goTo(page: offset)
                    } else {
                        self.setDocument(scanDoc, url: nil, dirty: true, suggestedName: "스캔_\(stamp).pdf")
                        self.pageTexts = texts
                        self.pageLines = result.lines
                        self.pageReports = Dictionary(uniqueKeysWithValues: reports.enumerated().map { ($0, $1) })
                    }
                    self.scannedPages = []
                    self.statusMessage = "스캔 \(files.count)쪽을 한국어 OCR 처리했습니다 (⌘S로 저장)"
                }
            } catch is CancellationError {
                DispatchQueue.main.async { self.isProcessing = false; self.showReview = true }
            } catch {
                DispatchQueue.main.async { self.isProcessing = false; self.errorMessage = "PDF 생성 실패: \(error.localizedDescription)" }
            }
        }
    }

    func finishCamera() {
        showCamera = false
        if !scannedPages.isEmpty || pendingScanCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showReview = true }
        }
    }

    func finishScanner() {
        showScanner = false
        if !scannedPages.isEmpty || pendingScanCount > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showReview = true }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return f.string(from: Date())
    }
}
