import Foundation
import CoreImage
import AppKit

/// 폴더 자동 OCR: 지정한 폴더에 PDF·사진이 들어오면 자동으로 보정 + 한국어 OCR 해서
/// '<폴더>/OCR 완료'에 저장하고, 원본은 '<폴더>/처리한 원본'으로 옮긴다. 앱이 켜져 있는 동안 동작.
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    struct LogEntry: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
        let date = Date()
    }

    @Published private(set) var folder: URL?
    @Published var enabled = false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "watchEnabled")
            enabled ? start() : stop()
        }
    }
    @Published private(set) var current: String?
    @Published private(set) var queued = 0
    @Published private(set) var doneCount = 0
    @Published private(set) var failCount = 0
    @Published private(set) var log: [LogEntry] = []

    static let doneFolder = "OCR 완료"
    static let originalsFolder = "처리한 원본"
    static let failedFolder = "OCR 실패"
    private static let supported: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "tif", "tiff"]

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var lastSizes: [String: Int] = [:]
    private var inFlight: Set<String> = []
    private let work = DispatchQueue(label: "folder.ocr", qos: .utility)   // 한 번에 하나씩

    private init() {
        if let p = UserDefaults.standard.string(forKey: "watchFolder") { folder = URL(fileURLWithPath: p) }
    }

    /// 테스트용: 저장된 설정을 건드리지 않고 지정 폴더 감시
    func testWatch(_ url: URL) {
        folder = url
        start()
        enabledForTest = true
    }
    private var enabledForTest = false
    private var isActive: Bool { enabled || enabledForTest }

    /// 앱 시작 시 호출: 지난번에 켜 두었으면 다시 감시 시작
    func startIfNeeded() {
        if UserDefaults.standard.bool(forKey: "watchEnabled"), folder != nil { enabled = true }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "이 폴더 감시"
        panel.message = "PDF나 사진을 넣으면 자동으로 한국어 OCR 할 폴더를 고르세요 (예: 스캐너 저장 폴더)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        UserDefaults.standard.set(url.path, forKey: "watchFolder")
        if enabled { stop(); start() } else { enabled = true }
    }

    func openResults() {
        guard let f = folder else { return }
        let done = f.appendingPathComponent(Self.doneFolder)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: done.path) ? done : f)
    }

    var statusText: String {
        guard folder != nil else { return "감시할 폴더를 골라 주세요" }
        guard isActive else { return "꺼짐" }
        if let c = current { return "처리 중: \(c)" + (queued > 1 ? " (대기 \(queued - 1)개)" : "") }
        return "새 파일을 기다리는 중"
    }

    // MARK: 감시

    private func start() {
        guard let folder, source == nil else { return }
        let fm = FileManager.default
        for sub in [Self.doneFolder, Self.originalsFolder] {
            try? fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            s.setEventHandler { [weak self] in self?.scan() }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        // 파일이 다 쓰였는지(크기 변화가 멈췄는지) 확인하려고 주기적으로도 살핌
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.scan() }
        scan()
    }

    private func stop() {
        source?.cancel(); source = nil
        timer?.invalidate(); timer = nil
        lastSizes = [:]
    }

    private func scan() {
        guard isActive, let folder else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        var seen = Set<String>()
        for url in items {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard v?.isDirectory != true, Self.supported.contains(url.pathExtension.lowercased()) else { continue }
            let key = url.path
            seen.insert(key)
            guard !inFlight.contains(key) else { continue }
            let size = v?.fileSize ?? 0
            // 두 번 연속 같은 크기여야 다 쓰인 것으로 봄
            if size > 0, lastSizes[key] == size {
                lastSizes[key] = nil
                enqueue(url)
            } else {
                lastSizes[key] = size
            }
        }
        lastSizes = lastSizes.filter { seen.contains($0.key) }
    }

    private func enqueue(_ url: URL) {
        inFlight.insert(url.path)
        queued += 1
        work.async { [weak self] in self?.process(url) }
    }

    // MARK: 처리

    private func process(_ url: URL) {
        DispatchQueue.main.async { self.current = url.lastPathComponent }
        let settings = OCRSettings.load()          // 도구 패널에서 바꾼 최신 설정 사용
        let fm = FileManager.default
        guard let folder else { return }
        let output = TempStore.newURL("pdf")
        var ok = false
        var detail = ""
        do {
            try autoreleasepool {
                if url.pathExtension.lowercased() == "pdf" {
                    let r = try PDFOCRJob.run(input: url, output: output, pages: nil, settings: settings,
                                              cancel: CancelToken()) { _, _ in }
                    detail = r.ocrPageCount > 0 ? "\(r.ocrPageCount)쪽 인식" : "이미 텍스트가 있어 그대로 저장"
                } else {
                    guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                        throw AppError.message("이미지를 읽을 수 없습니다")
                    }
                    let files = ImageProcessor.processPages(img, options: settings.processing, detectDocument: true)
                        .compactMap { TempStore.saveJPEG($0.0) }
                    guard !files.isEmpty else { throw AppError.message("보정에 실패했습니다") }
                    _ = try ScanPDFJob.run(imageFiles: files, languages: settings.languages, pageSize: settings.pageSize,
                                           output: output, cancel: CancelToken()) { _, _ in }
                    files.forEach { try? fm.removeItem(at: $0) }
                    detail = "\(files.count)쪽 인식"
                }
            }
            let base = url.deletingPathExtension().lastPathComponent
            let dest = Self.unique(folder.appendingPathComponent(Self.doneFolder).appendingPathComponent(base + ".pdf"))
            try fm.moveItem(at: output, to: dest)
            let orig = Self.unique(folder.appendingPathComponent(Self.originalsFolder).appendingPathComponent(url.lastPathComponent))
            try? fm.moveItem(at: url, to: orig)
            ok = true
        } catch {
            detail = error.localizedDescription
            // 같은 파일을 계속 다시 시도하지 않도록 실패 폴더로 옮김
            let failed = folder.appendingPathComponent(Self.failedFolder)
            try? fm.createDirectory(at: failed, withIntermediateDirectories: true)
            try? fm.moveItem(at: url, to: Self.unique(failed.appendingPathComponent(url.lastPathComponent)))
            try? fm.removeItem(at: output)
        }
        DispatchQueue.main.async {
            self.inFlight.remove(url.path)
            self.queued -= 1
            self.current = nil
            if ok { self.doneCount += 1 } else { self.failCount += 1 }
            self.log.insert(LogEntry(name: url.lastPathComponent, ok: ok, detail: detail), at: 0)
            if self.log.count > 30 { self.log.removeLast() }
        }
    }

    /// 같은 이름이 있으면 '이름 (2).pdf' 식으로
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let u = dir.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }
}
