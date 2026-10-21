import Foundation
import CoreImage
import PDFKit

typealias ProgressHandler = (_ fraction: Double, _ message: String) -> Void

/// 여러 작업자가 동시에 보고하는 진행 상황을 하나로 모은다.
final class ProgressCounter {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let handler: ProgressHandler

    init(total: Int, handler: @escaping ProgressHandler) {
        self.total = max(1, total)
        self.handler = handler
    }

    func finish(_ message: (Int, Int) -> String) {
        lock.lock()
        done += 1
        let d = done
        lock.unlock()
        handler(Double(d) / Double(total), message(d, total))
    }
}

/// 기존 PDF에 한국어 OCR 텍스트 층을 입힌다. 여러 페이지를 동시에 처리한다.
/// 입력·출력·중간 결과는 모두 파일로 다뤄 1000쪽이 넘어도 메모리 사용량이 일정하다.
enum PDFOCRJob {
    struct Result {
        let texts: [Int: String]
        let reports: [Int: ProcessReport]
        let lines: [Int: [OCRLine]]
        let ocrPageCount: Int
    }

    private enum Outcome {
        case keep(text: String?)
        case ocr(pages: [(file: URL, text: String, report: ProcessReport, lines: [OCRLine])])
    }

    static func run(input: URL, output: URL, pages: Set<Int>?, settings: OCRSettings,
                    cancel: CancelToken, progress: @escaping ProgressHandler) throws -> Result {
        guard let src = PDFDocument(url: input) else { throw AppError.message("PDF를 읽을 수 없습니다.") }
        let total = src.pageCount
        // 사진을 넣은 PDF는 배경이 남아 있을 수 있으므로 문서 영역 자르기도 적용
        // (배경이 종이보다 확실히 어두울 때만 동작해 일반 스캔의 여백은 보존됨)
        let options = settings.processing
        let workers = MemoryBudget.workers(forDPI: settings.dpi)
        // PDFDocument는 스레드 간 공유가 안전하지 않으므로 작업자마다 따로 연다 (파일에서 필요한 쪽만 읽음)
        let docs = (0..<workers).map { $0 == 0 ? src : (PDFDocument(url: input) ?? src) }
        let counter = ProgressCounter(total: total, handler: progress)
        progress(0, "\(workers)쪽씩 동시에 처리 중…")

        let outcomes: [Outcome] = try Parallel.map(total, workers: workers) { i, w in
            if cancel.isCancelled { throw CancellationError() }
            guard let page = docs[w].page(at: i) else { return .keep(text: nil) }
            let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = existing.count > 20 && PDFTextProbe.hasText(page)
            if !(pages?.contains(i) ?? true) || (settings.skipTextPages && hasText) {
                counter.finish { d, t in "\(d)/\(t)쪽 완료 (\(i + 1)쪽은 이미 텍스트 있음)" }
                return .keep(text: hasText ? existing : nil)
            }

            guard let rendered = Timing.measure("PDF 렌더", { SearchablePDF.render(page, dpi: CGFloat(settings.dpi)) })
            else { return .keep(text: nil) }
            var results = Timing.measure("보정 전체", {
                ImageProcessor.processPages(CIImage(cgImage: rendered), options: options, detectDocument: true)
            })
            if results.isEmpty { results = [(rendered, ProcessReport())] }

            var made: [(file: URL, text: String, report: ProcessReport, lines: [OCRLine])] = []
            for (image, report) in results {
                if cancel.isCancelled { throw CancellationError() }
                let lines = try Timing.measure("최종 OCR \(image.width)x\(image.height)") {
                    try OCREngine.recognize(image, languages: settings.languages)
                }
                // 쪽 크기: 지정 크기, 아니면 원본 쪽 크기(책 모드로 나뉘면 원본 펼침의 절반) → 모든 쪽 같은 크기 유지
                let size: CGSize
                if let fixed = settings.pageSize.portraitSize {
                    size = fixed
                } else {
                    var orig = page.bounds(for: .mediaBox).size
                    if page.rotation % 180 != 0 { orig = CGSize(width: orig.height, height: orig.width) }
                    size = results.count > 1 ? CGSize(width: orig.width / CGFloat(results.count), height: orig.height) : orig
                }
                let pageFile = TempStore.newURL("pdf")
                guard let writer = SearchablePDF.Writer(url: pageFile) else { continue }
                let placed = Timing.measure("PDF 페이지 생성") { () -> [OCRLine] in
                    let p = writer.addPage(image: image, lines: lines, pageSize: size); writer.close(); return p
                }
                made.append((pageFile, OCREngine.layoutText(lines), report, placed))
            }
            guard !made.isEmpty else { return .keep(text: nil) }
            counter.finish { d, t in "\(d)/\(t)쪽 한국어 인식 완료" }
            return .ocr(pages: made)
        }

        // 원래 순서대로 조립 → 파일로 저장
        progress(1, "PDF 저장 중…")
        let out = PDFDocument()
        var texts: [Int: String] = [:]
        var reports: [Int: ProcessReport] = [:]
        var lineMap: [Int: [OCRLine]] = [:]
        var ocrCount = 0
        var pageFiles: [URL] = []
        for (i, outcome) in outcomes.enumerated() {
            switch outcome {
            case .keep(let text):
                if let text { texts[out.pageCount] = text }
                if let copy = src.page(at: i)?.copy() as? PDFPage { out.insert(copy, at: out.pageCount) }
            case .ocr(let made):
                for m in made {
                    pageFiles.append(m.file)
                    // 메모리 매핑: 실제 메모리에 올리지 않고 파일에서 필요할 때 읽음
                    guard let data = try? Data(contentsOf: m.file, options: .alwaysMapped),
                          let one = PDFDocument(data: data), let p = one.page(at: 0) else { continue }
                    texts[out.pageCount] = m.text
                    reports[out.pageCount] = m.report
                    lineMap[out.pageCount] = m.lines
                    out.insert(p, at: out.pageCount)
                    ocrCount += 1
                }
            }
        }
        guard out.write(to: output) else { throw AppError.message("PDF 저장에 실패했습니다.") }
        pageFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        return Result(texts: texts, reports: reports, lines: lineMap, ocrPageCount: ocrCount)
    }
}

/// 보정된 스캔 이미지(디스크의 JPEG)들을 OCR해서 검색 가능한 PDF 파일로 만든다.
/// 몇 쪽씩 동시에 인식하고, 끝난 쪽은 바로 파일에 써서 메모리에 쌓지 않는다.
enum ScanPDFJob {
    struct Output {
        var texts: [Int: String] = [:]
        var lines: [Int: [OCRLine]] = [:]
    }

    @discardableResult
    static func run(imageFiles: [URL], languages: [String], pageSize mode: PageSizeMode = .auto, output: URL,
                    cancel: CancelToken, progress: @escaping ProgressHandler) throws -> Output {
        guard let writer = SearchablePDF.Writer(url: output) else { throw AppError.message("PDF 생성에 실패했습니다.") }
        // 모든 쪽을 같은 크기로: 지정 크기 또는 전체 비율의 중간값
        let pixelSizes = imageFiles.map { TempStore.pixelSize($0) ?? CGSize(width: 1240, height: 1754) }
        let target = mode.portraitSize ?? SearchablePDF.uniformSize(forPixels: pixelSizes)
        let workers = MemoryBudget.workers(forDPI: 300)
        let counter = ProgressCounter(total: imageFiles.count, handler: progress)
        var result = Output()
        progress(0, "한국어 인식 중…")

        var start = 0
        while start < imageFiles.count {
            let chunk = Array(imageFiles[start..<min(start + workers * 2, imageFiles.count)])
            let results: [[OCRLine]] = try Parallel.map(chunk.count, workers: workers) { i, _ in
                if cancel.isCancelled { throw CancellationError() }
                guard let img = TempStore.loadImage(chunk[i]) else { return [] }
                let lines = try Timing.measure("최종 OCR \(img.width)x\(img.height)") {
                    try OCREngine.recognize(img, languages: languages)
                }
                counter.finish { d, t in "스캔 \(d)/\(t)쪽 한국어 인식 완료" }
                return lines
            }
            for (k, lines) in results.enumerated() {
                let url = chunk[k]
                result.lines[start + k] = autoreleasepool {
                    writer.addPage(jpegFile: url, lines: lines, pageSize: target)
                }
                result.texts[start + k] = OCREngine.layoutText(lines)
            }
            start += chunk.count
        }
        writer.close()
        return result
    }
}
