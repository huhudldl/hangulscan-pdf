import SwiftUI
import PDFKit

struct ContentView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if model.showAnnotationBar && model.document != nil {
                    AnnotationBar()
                    Divider()
                }
                ZStack {
                    if model.document != nil {
                        PDFKitView(pdfView: model.pdfView)
                    } else {
                        HomeView()
                    }
                    if model.isProcessing { ProgressOverlay() }
                }
                .overlay(alignment: .topTrailing) {
                    if model.focusMode { RestoreMenuButton().padding(12) }
                }
                if model.showStatusBar {
                    Divider()
                    StatusBar()
                }
            }
            .inspector(isPresented: $model.showTools) {
                ToolsPanel()
                    .inspectorColumnWidth(min: 270, ideal: 310, max: 440)
            }
            .toolbar { MainToolbar() }
        }
        .toolbar(model.showToolbar ? .automatic : .hidden, for: .windowToolbar)
        .onExitCommand { if model.focusMode { model.toggleFocusMode() } }
        .navigationTitle(model.title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "문서에서 찾기")
        .onSubmit(of: .search) { model.find() }
        .onChange(of: model.searchText) { _, new in if new.isEmpty { model.clearSearch() } }
        .dropDestination(for: URL.self) { urls, _ in
            model.handle(urls: urls, askMerge: true)
            return true
        }
        .sheet(isPresented: $model.showCamera) { CameraScanView().environmentObject(model) }
        .sheet(isPresented: $model.showReview) { ScanReviewView().environmentObject(model) }
        .sheet(isPresented: $model.showScanner) { ScannerSheet().environmentObject(model) }
        .sheet(isPresented: $model.showOrganizer) { PageOrganizerView().environmentObject(model) }
        .sheet(isPresented: $model.showCorrection) { CorrectionView().environmentObject(model) }
        .sheet(isPresented: $model.showCompress) { CompressView().environmentObject(model) }
        .sheet(isPresented: $model.showSignaturePad) { SignaturePad().environmentObject(model) }
        .alert("알림", isPresented: Binding(get: { model.errorMessage != nil },
                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - 도구 막대

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var model: ViewerModel
    @State private var pageField = ""

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.openPanel() } label: { Label("열기", systemImage: "folder") }
                .help("PDF 또는 이미지 열기 (⌘O)")
            Button { model.save() } label: { Label("저장", systemImage: "square.and.arrow.down") }
                .help("저장 (⌘S)")
                .disabled(model.document == nil)
            Button { model.printDocument() } label: { Label("인쇄", systemImage: "printer") }
                .help("인쇄 (⌘P)")
                .disabled(model.document == nil)
        }

        ToolbarItemGroup(placement: .principal) {
            HStack(spacing: 4) {
                Button { model.previousPage() } label: { Image(systemName: "chevron.up") }
                    .help("이전 페이지")
                Button { model.nextPage() } label: { Image(systemName: "chevron.down") }
                    .help("다음 페이지")
                TextField("", text: $pageField)
                    .frame(width: 38)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let n = Int(pageField) { model.goTo(page: n - 1) } }
                    .onAppear { pageField = "\(model.currentPage + 1)" }
                    .onChange(of: model.currentPage) { _, p in pageField = "\(p + 1)" }
                Text("/ \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()

                Divider().frame(height: 18).padding(.horizontal, 6)

                Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("축소 (⌘-)")
                Menu("\(model.zoomPercent)%") {
                    Button("폭에 맞추기") { model.fitWidth() }
                    Button("실제 크기") { model.actualSize() }
                    Divider()
                    ForEach([50, 75, 100, 125, 150, 200, 300, 400], id: \.self) { p in
                        Button("\(p)%") { model.setZoom(p) }
                    }
                }
                .frame(width: 76)
                .help("확대/축소 비율")
                Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("확대 (⌘+)")
            }
            .disabled(model.document == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button { model.showCamera = true } label: { Label("카메라로 스캔 (iPhone 연속성 카메라 지원)", systemImage: "camera.viewfinder") }
                Button { model.showScanner = true } label: { Label("스캐너로 스캔", systemImage: "scanner") }
                Button { model.importImagesPanel() } label: { Label("사진/이미지 가져오기", systemImage: "photo.on.rectangle") }
                if !model.scannedPages.isEmpty {
                    Divider()
                    Button("스캔 검토 (\(model.scannedPages.count)쪽)") { model.showReview = true }
                }
            } label: {
                Label("스캔", systemImage: "doc.viewfinder")
            }
            .help("문서 스캔 — 자동 수평 보정")

            Button { model.runOCR(currentPageOnly: false) } label: {
                Label("한국어 OCR", systemImage: "text.viewfinder")
            }
            .help("전체 문서 한국어 OCR (⇧⌘O)")
            .disabled(model.document == nil || model.isProcessing)

            Button { model.showAnnotationBar.toggle(); if !model.showAnnotationBar { model.annotTool = .select } } label: {
                Label("주석", systemImage: "pencil.tip.crop.circle")
            }
            .help("주석 도구: 형광펜·메모·글상자·펜·도형·서명 (⇧⌘A)")
            .disabled(model.document == nil)

            Button { model.rotateCurrentPage(clockwise: true) } label: { Label("회전", systemImage: "rotate.right") }
                .help("현재 페이지 오른쪽으로 회전 (⌘R)")
                .disabled(model.document == nil)

            Menu {
                Picker("페이지 보기", selection: $model.displayMode) {
                    Text("한 페이지").tag(PDFDisplayMode.singlePage)
                    Text("연속 스크롤").tag(PDFDisplayMode.singlePageContinuous)
                    Text("두 페이지").tag(PDFDisplayMode.twoUp)
                    Text("두 페이지 연속").tag(PDFDisplayMode.twoUpContinuous)
                }
                .pickerStyle(.inline)
            } label: {
                Label("보기 방식", systemImage: "rectangle.split.2x1")
            }
            .help("페이지 보기 방식")

            Button { model.showTools.toggle() } label: { Label("도구", systemImage: "sidebar.right") }
                .help("도구 패널 보이기/숨기기 (⌥⌘I)")

            Button { model.toggleFocusMode() } label: { Label("메뉴 숨기기", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("메뉴를 모두 숨기고 문서만 보기 (⇧⌘F) — esc로 다시 보이기")
        }
    }
}

// MARK: - 왼쪽 사이드바

struct SidebarView: View {
    @EnvironmentObject var model: ViewerModel
    enum Tab: String, CaseIterable { case pages = "페이지", outline = "목차", search = "검색" }
    @State private var tab: Tab = .pages

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch tab {
            case .pages:
                if model.document != nil {
                    ThumbnailsView(pdfView: model.pdfView, pageCount: model.pageCount)
                        .contextMenu { PageMenuItems() }
                    Divider()
                    PageEditBar()
                } else {
                    placeholder("열린 문서가 없습니다")
                }
            case .outline:
                if model.outline.isEmpty {
                    placeholder("목차(책갈피)가 없는 문서입니다")
                } else {
                    List(model.outline, children: \.children) { item in
                        Button(item.title) { if let p = item.pageIndex { model.goTo(page: p) } }
                            .buttonStyle(.plain)
                    }
                }
            case .search:
                if model.searchResults.isEmpty {
                    placeholder("오른쪽 위 검색창에 단어를 입력하고 Return을 누르세요")
                } else {
                    List(model.searchResults.indices, id: \.self) { i in
                        SearchRow(index: i, selection: model.searchResults[i], selected: i == model.searchIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectResult(i) }
                    }
                }
            }
        }
        .onChange(of: model.searchResults.count) { _, n in if n > 0 { tab = .search } }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct SearchRow: View {
    @EnvironmentObject var model: ViewerModel
    let index: Int
    let selection: PDFSelection
    let selected: Bool

    var body: some View {
        let page = selection.pages.first.flatMap { model.document?.index(for: $0) } ?? 0
        let ctx = selection.copy() as! PDFSelection
        ctx.extend(atStart: 12)
        ctx.extend(atEnd: 16)
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(page + 1)쪽").font(.caption).foregroundStyle(.secondary)
            Text((ctx.string ?? "").replacingOccurrences(of: "\n", with: " "))
                .font(.callout).lineLimit(2)
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

// MARK: - 시작 화면

struct HomeView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text("한글스캔 PDF").font(.largeTitle.bold())
                Text("PDF 보기 · 한국어 OCR · 자동 수평 보정 스캔").foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                HomeCard(icon: "folder", title: "PDF 열기", subtitle: "⌘O") { model.openPanel() }
                HomeCard(icon: "camera.viewfinder", title: "카메라로 스캔", subtitle: "Mac·iPhone 카메라") { model.showCamera = true }
                HomeCard(icon: "scanner", title: "스캐너로 스캔", subtitle: "평판·급지 스캐너") { model.showScanner = true }
                HomeCard(icon: "photo.on.rectangle", title: "사진 가져오기", subtitle: "찍어둔 문서 사진") { model.importImagesPanel() }
            }
            Text("PDF나 문서 사진을 여기로 끌어다 놓아도 됩니다")
                .font(.callout).foregroundStyle(.tertiary)
            RecentDocumentsStrip()
            if !model.scannedPages.isEmpty || model.pendingScanCount > 0 {
                Button("스캔 검토하기 (\(model.scannedPages.count)쪽)") { model.showReview = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct HomeCard: View {
    let icon: String, title: String, subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, height: 130)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(hover ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: hover ? 2 : 1))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.05), radius: hover ? 8 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 오른쪽 도구 패널

struct ToolsPanel: View {
    @EnvironmentObject var model: ViewerModel
    @AppStorage("toolsTab") private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("인식").tag(0)
                Text("텍스트").tag(1)
                Text("도우미").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            switch tab {
            case 1: textTab
            case 2: AssistantPanel()
            default: recognizeTab
            }
        }
    }

    // MARK: 인식 탭: OCR·스캔 보정·폴더 자동 OCR
    private var recognizeTab: some View {
        Form {
            Section("한국어 OCR") {
                Toggle("한국어", isOn: .constant(true)).disabled(true)
                Toggle("영어 함께 인식", isOn: $model.settings.english)
                Toggle("일본어", isOn: $model.settings.japanese)
                Toggle("한자(중국어 간체)", isOn: $model.settings.chinese)
                Picker("해상도", selection: $model.settings.dpi) {
                    Text("200 dpi (빠름)").tag(200.0)
                    Text("300 dpi (권장)").tag(300.0)
                    Text("400 dpi (작은 글씨)").tag(400.0)
                    Text("600 dpi (아주 작은 글씨·느림)").tag(600.0)
                }
                Picker("출력 쪽 크기", selection: $model.settings.pageSize) {
                    ForEach(PageSizeMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("텍스트 있는 페이지 건너뛰기", isOn: $model.settings.skipTextPages)
                HStack {
                    Button("현재 페이지") { model.runOCR(currentPageOnly: true) }
                    Button("전체 문서 OCR") { model.runOCR(currentPageOnly: false) }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(model.document == nil || model.isProcessing)
            }

            Section {
                Toggle(isOn: $model.settings.bookMode) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("책 모드")
                        Text("펼친 양쪽 나누기 · 휜 줄 펴기 · 테두리·그림자 정리").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("자동 수평 보정", isOn: $model.settings.autoDeskew)
                Toggle("자동 방향 감지 (90°/180°)", isOn: $model.settings.autoOrientation)
                Toggle("문서 영역 자동 자르기", isOn: $model.settings.cropDocument)
                Toggle("문서 선명하게 (흑백 강조)", isOn: $model.settings.enhance)
            } header: {
                Text("스캔 보정")
            } footer: {
                Text("글줄 방향과 투영 분석으로 기울기를 0.05° 단위까지 찾아 바로잡습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            FolderWatchSection()
        }
        .formStyle(.grouped)
    }

    // MARK: 텍스트 탭: 인식된 텍스트·교정·내보내기
    private var textTab: some View {
        Form {
            Section {
                if let r = model.pageReports[model.currentPage] {
                    Label(r.summary, systemImage: "level")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(model.currentPageText.isEmpty ? "이 페이지에는 인식된 텍스트가 없습니다.\n스캔 문서라면 위의 OCR을 실행하세요." : model.currentPageText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(model.currentPageText.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, maxHeight: 460)
                HStack {
                    Button("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.currentPageText, forType: .string)
                        model.statusMessage = "\(model.currentPage + 1)쪽 텍스트를 복사했습니다"
                    }
                    .disabled(model.currentPageText.isEmpty)
                    Menu("내보내기") {
                        Button("텍스트 (줄 단위)…") { model.exportText() }
                        Button("문단 텍스트…") { model.exportParagraphText() }
                        Button("표 → 엑셀(CSV)…") { model.exportTables() }
                    }
                    .fixedSize()
                    .disabled(model.document == nil || model.isProcessing)
                }
                HStack {
                    Button {
                        model.showCorrection = true
                    } label: {
                        Label("교정하기…", systemImage: "character.cursor.ibeam")
                    }
                    .disabled(model.document == nil)
                    if model.reviewCount > 0 {
                        Text("확인 필요 \(model.reviewCount)줄").font(.caption).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("인식된 텍스트 · \(model.currentPage + 1)쪽")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 상태 표시줄 / 진행 표시

struct StatusBar: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        HStack(spacing: 12) {
            if model.document != nil {
                if model.isPasswordProtected {
                    Image(systemName: "lock.fill").help("저장할 때 암호가 걸립니다")
                }
                Text("\(model.currentPage + 1) / \(model.pageCount)쪽").monospacedDigit()
                Text("\(model.zoomPercent)%").monospacedDigit()
            }
            if model.pendingScanCount > 0 {
                ProgressView().controlSize(.small)
                Text("스캔 보정 중 \(model.pendingScanCount)장")
            }
            Text(model.statusMessage).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }
}

struct ProgressOverlay: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "text.viewfinder").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("처리 중").font(.headline)
                ProgressView(value: model.progress).frame(width: 280)
                Text(model.progressMessage).font(.callout).foregroundStyle(.secondary)
                Button("취소") { model.cancelProcessing() }
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        }
    }
}

// MARK: - 페이지 편집 막대 / 메뉴

struct PageMenuItems: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        Button("페이지 정리…") { model.showOrganizer = true }
        Divider()
        Button("\(model.currentPage + 1)쪽 삭제") { model.deleteCurrentPage() }
            .disabled(model.pageCount < 2)
        Button("오른쪽으로 회전") { model.rotateCurrentPage(clockwise: true) }
        Button("왼쪽으로 회전") { model.rotateCurrentPage(clockwise: false) }
        Divider()
        Button("이 페이지 뒤에 PDF 삽입…") { model.mergePanel(afterCurrentPage: true) }
        Button("문서 끝에 PDF 합치기…") { model.mergePanel(afterCurrentPage: false) }
    }
}

struct PageEditBar: View {
    @EnvironmentObject var model: ViewerModel
    var body: some View {
        HStack(spacing: 2) {
            Button { model.deleteCurrentPage() } label: { Image(systemName: "trash") }
                .help("현재 페이지 삭제 (⇧⌘D) — ⌘Z로 되돌리기")
                .disabled(model.pageCount < 2)
            Button { model.rotateCurrentPage(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("왼쪽으로 회전")
            Button { model.rotateCurrentPage(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("오른쪽으로 회전")
            Button { model.showOrganizer = true } label: { Image(systemName: "square.grid.2x2") }
                .help("페이지 정리 — 순서 바꾸기·여러 쪽 삭제·추출 (⌥⌘P)")
            Spacer()
            Menu {
                Button("문서 끝에 PDF 합치기…") { model.mergePanel(afterCurrentPage: false) }
                Button("\(model.currentPage + 1)쪽 뒤에 PDF 삽입…") { model.mergePanel(afterCurrentPage: true) }
            } label: {
                Label("합치기", systemImage: "doc.on.doc")
            }
            .fixedSize()
            .help("다른 PDF를 합치기")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// 메뉴를 모두 숨겼을 때 오른쪽 위에 떠 있는 '메뉴 보이기' 단추
struct RestoreMenuButton: View {
    @EnvironmentObject var model: ViewerModel
    @State private var hover = false
    var body: some View {
        Button { model.toggleFocusMode() } label: {
            Label(hover ? "메뉴 보이기 (esc)" : "메뉴", systemImage: "menubar.rectangle")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.regularMaterial))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(hover ? 1 : 0.55)
        .onHover { hover = $0 }
        .help("숨긴 메뉴 다시 보이기 (esc 또는 ⇧⌘F)")
    }
}

// MARK: - 폴더 자동 OCR

struct FolderWatchSection: View {
    @ObservedObject var watcher = FolderWatcher.shared

    var body: some View {
        Section {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(watcher.folder?.lastPathComponent ?? "폴더를 고르지 않음")
                    .lineLimit(1).truncationMode(.middle)
                    .help(watcher.folder?.path ?? "")
                Spacer()
                Button("고르기…") { watcher.chooseFolder() }
            }
            Toggle("자동 OCR 켜기", isOn: $watcher.enabled)
                .disabled(watcher.folder == nil)
            HStack(spacing: 6) {
                if watcher.current != nil { ProgressView().controlSize(.small) }
                Text(watcher.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if watcher.doneCount + watcher.failCount > 0 {
                    Text("완료 \(watcher.doneCount)" + (watcher.failCount > 0 ? " · 실패 \(watcher.failCount)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !watcher.log.isEmpty {
                ForEach(watcher.log.prefix(4)) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(e.ok ? .green : .orange)
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(e.detail).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.caption)
                }
            }
            Button("결과 폴더 열기") { watcher.openResults() }
                .disabled(watcher.folder == nil)
        } header: {
            Text("폴더 자동 OCR")
        } footer: {
            Text("이 폴더에 PDF나 사진이 들어오면 위 설정대로 보정·한국어 OCR 후 'OCR 완료' 폴더에 저장하고, 원본은 '처리한 원본' 폴더로 옮깁니다. 앱이 켜져 있을 때만 동작합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 시작 화면의 최근 문서

struct RecentDocumentsStrip: View {
    @EnvironmentObject var model: ViewerModel
    @State private var urls: [URL] = []
    @State private var thumbs: [URL: NSImage] = [:]

    var body: some View {
        if !urls.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("최근 문서").font(.headline)
                    Spacer()
                    Button("목록 지우기") { RecentDocuments.clear(); urls = [] }
                        .buttonStyle(.borderless).font(.caption)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(urls.prefix(12), id: \.self) { url in
                            Button { model.open(url: url) } label: {
                                VStack(spacing: 6) {
                                    Group {
                                        if let t = thumbs[url] { Image(nsImage: t).resizable().scaledToFit() }
                                        else { Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary) }
                                    }
                                    .frame(width: 90, height: 120)
                                    .background(Color.white)
                                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                        .frame(width: 110)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(url.path)
                            .task {
                                guard thumbs[url] == nil else { return }
                                let img = await Task.detached { RecentDocuments.thumbnail(url) }.value
                                thumbs[url] = img
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: 760)
        } else {
            Color.clear.frame(height: 0).onAppear { urls = RecentDocuments.urls }
        }
    }
}
