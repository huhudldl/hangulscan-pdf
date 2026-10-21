import SwiftUI
import Quartz
import ImageCaptureCore

// MARK: - 스캔 검토

struct ScanReviewView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("스캔 검토").font(.title3.bold())
                    Text("자동으로 문서 영역을 자르고 수평을 맞췄습니다. 순서·회전을 확인한 뒤 PDF로 만드세요.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("추가") {
                    Button("카메라로 더 스캔") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showCamera = true } }
                    Button("스캐너로 더 스캔") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showScanner = true } }
                    Button("이미지 가져오기…") { model.importImagesPanel() }
                }
                .fixedSize()
            }
            .padding(16)
            Divider()

            ScrollView {
                if model.scannedPages.isEmpty && model.pendingScanCount == 0 {
                    Text("스캔한 페이지가 없습니다").foregroundStyle(.secondary).padding(60)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(model.scannedPages.enumerated()), id: \.element.id) { idx, page in
                        ScanTile(index: idx, page: page, selected: selected == page.id)
                            .onTapGesture { selected = page.id }
                    }
                    if model.pendingScanCount > 0 {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("수평 보정 중… \(model.pendingScanCount)장").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(height: 260)
                    }
                }
                .padding(18)
            }
            .frame(minWidth: 820, minHeight: 460)
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            HStack(spacing: 16) {
                Picker("쪽 크기", selection: $model.settings.pageSize) {
                    ForEach(PageSizeMode.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Toggle("책 모드", isOn: $model.settings.bookMode)
                    .help("펼친 양쪽을 두 쪽으로 나누고, 휜 글줄을 펴고, 테두리·가운데 그림자를 정리합니다")
                Toggle("자동 수평 보정", isOn: $model.settings.autoDeskew)
                Toggle("문서 영역 자르기", isOn: $model.settings.cropDocument)
                Toggle("선명하게", isOn: $model.settings.enhance)
                Button("다시 보정") { model.reprocessScans() }
                    .disabled(model.scannedPages.isEmpty)
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            HStack(spacing: 12) {
                Spacer()
                Button("취소") { dismiss() }
                if model.document != nil {
                    Button("현재 문서 뒤에 추가") { model.buildPDFFromScans(appendToCurrent: true) }
                        .disabled(model.scannedPages.isEmpty || model.pendingScanCount > 0)
                }
                Button("새 PDF 만들기 (한국어 OCR)") { model.buildPDFFromScans(appendToCurrent: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scannedPages.isEmpty || model.pendingScanCount > 0)
            }
            .padding(14)
        }
        .frame(minWidth: 900)
    }
}

struct ScanTile: View {
    @EnvironmentObject var model: ViewerModel
    let index: Int
    let page: ScanPage
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSImage(cgImage: page.thumbnail, size: .zero))
                .resizable().scaledToFit()
                .frame(height: 230)
                .background(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(index + 1)쪽").font(.caption.bold())
            Text(page.report.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 2) {
                tileButton("arrow.left", "앞으로") { move(-1) }.disabled(index == 0)
                tileButton("rotate.left", "왼쪽 회전") { rotate(false) }
                tileButton("rotate.right", "오른쪽 회전") { rotate(true) }
                tileButton("trash", "삭제") {
                    try? FileManager.default.removeItem(at: page.imageURL)
                    model.scannedPages.removeAll { $0.id == page.id }
                }
                tileButton("arrow.right", "뒤로") { move(1) }.disabled(index == model.scannedPages.count - 1)
            }
        }
    }

    private func tileButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 18) }
            .buttonStyle(.borderless).help(help)
    }

    private func rotate(_ cw: Bool) {
        guard let i = model.scannedPages.firstIndex(where: { $0.id == page.id }) else { return }
        let old = model.scannedPages[i].imageURL
        guard let img = TempStore.loadImage(old),
              let url = TempStore.saveJPEG(ImageProcessor.rotate90(img, clockwise: cw), quality: 0.92),
              let thumb = TempStore.thumbnail(url) else { return }
        model.scannedPages[i].imageURL = url
        model.scannedPages[i].thumbnail = thumb
        try? FileManager.default.removeItem(at: old)
    }

    private func move(_ d: Int) {
        guard let i = model.scannedPages.firstIndex(where: { $0.id == page.id }) else { return }
        let j = i + d
        guard j >= 0, j < model.scannedPages.count else { return }
        model.scannedPages.swapAt(i, j)
    }
}

// MARK: - 스캐너 (평판/급지 스캐너, 네트워크 복합기)

final class ScannerHostView: NSView, IKDeviceBrowserViewDelegate, IKScannerDeviceViewDelegate {
    let browser = IKDeviceBrowserView(frame: .zero)
    let scannerView = IKScannerDeviceView(frame: .zero)
    var onScan: ((URL) -> Void)?
    private let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HangulScan", isDirectory: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        browser.delegate = self
        browser.displaysLocalScanners = true
        browser.displaysNetworkScanners = true
        browser.displaysLocalCameras = false
        browser.displaysNetworkCameras = false
        browser.mode = .table

        scannerView.delegate = self
        scannerView.transferMode = .fileBased
        scannerView.downloadsDirectory = tempDir
        scannerView.documentName = "scan"
        scannerView.displaysDownloadsDirectoryControl = false
        scannerView.displaysPostProcessApplicationControl = false
        scannerView.mode = .advanced
        scannerView.hasDisplayModeAdvanced = true
        scannerView.hasDisplayModeSimple = true

        for v in [browser, scannerView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            browser.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.topAnchor.constraint(equalTo: topAnchor),
            browser.bottomAnchor.constraint(equalTo: bottomAnchor),
            browser.widthAnchor.constraint(equalToConstant: 220),
            scannerView.leadingAnchor.constraint(equalTo: browser.trailingAnchor),
            scannerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scannerView.topAnchor.constraint(equalTo: topAnchor),
            scannerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func deviceBrowserView(_ deviceBrowserView: IKDeviceBrowserView!, selectionDidChange device: ICDevice!) {
        if let s = device as? ICScannerDevice { scannerView.scannerDevice = s }
    }

    func scannerDeviceView(_ scannerDeviceView: IKScannerDeviceView!, didScanTo url: URL!, error: Error!) {
        if let url { onScan?(url) }
    }
}

struct ScannerRepresentable: NSViewRepresentable {
    let onScan: (URL) -> Void
    func makeNSView(context: Context) -> ScannerHostView {
        let v = ScannerHostView(frame: .zero)
        v.onScan = onScan
        return v
    }
    func updateNSView(_ nsView: ScannerHostView, context: Context) {}
}

struct ScannerSheet: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("스캐너로 스캔").font(.title3.bold())
                Spacer()
                Text("스캔한 페이지는 자동으로 수평 보정됩니다 · \(model.scannedPages.count + model.pendingScanCount)쪽")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(12)
            ScannerRepresentable { url in
                model.importScans([.file(url)])
            }
            .frame(minWidth: 900, minHeight: 580)
            HStack {
                Text("왼쪽 목록에 스캐너가 보이지 않으면 전원과 Wi‑Fi/USB 연결을 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("완료") { model.finishScanner() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}
