import Foundation
import CoreImage
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// 터미널 테스트 모드: HangulScan --selftest <입력 이미지|PDF> <출력.pdf> [--force]
enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        guard args.count >= 2 else {
            print("사용법: HangulScan --selftest <입력> <출력.pdf> [--force]")
            return 1
        }
        let input = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[1])
        var settings = OCRSettings()
        settings.skipTextPages = !args.contains("--force")
        settings.bookMode = args.contains("--book")
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let m = PageSizeMode(rawValue: args[i + 1]) { settings.pageSize = m }
        if let i = args.firstIndex(of: "--dpi"), i + 1 < args.count, let d = Double(args[i + 1]) { settings.dpi = d }
        let start = Date()
        do {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir), isDir.boolValue {
                // 폴더: 안의 사진 전부를 스캔으로 보정 → 한 PDF로
                let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
                    .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let opts = settings.processing
                let counter = ProgressCounter(total: files.count) { _, m in print("  · \(m)") }
                let jpgs: [URL?] = try Parallel.map(files.count, workers: MemoryBudget.workers(forDPI: 300)) { i, _ in
                    autoreleasepool {
                        defer { counter.finish { d, t in "보정 \(d)/\(t)" } }
                        guard let ci = CIImage(contentsOf: files[i], options: [.applyOrientationProperty: true]),
                              let (cg, _) = ImageProcessor.process(ci, options: opts, detectDocument: true) else { return nil }
                        return TempStore.saveJPEG(cg)
                    }
                }
                _ = try ScanPDFJob.run(imageFiles: jpgs.compactMap { $0 }, languages: settings.languages, pageSize: settings.pageSize, output: output,
                                       cancel: CancelToken()) { _, m in print("  · \(m)") }
            } else if input.pathExtension.lowercased() == "pdf" {
                let r = try PDFOCRJob.run(input: input, output: output, pages: nil, settings: settings,
                                          cancel: CancelToken()) { _, m in print("  · \(m)") }
                for (i, rep) in r.reports.sorted(by: { $0.key < $1.key }) { print("페이지 \(i + 1): \(rep.summary)") }
                for (i, t) in r.texts.sorted(by: { $0.key < $1.key }) { print("--- 페이지 \(i + 1) ---\n\(t)") }
            } else {
                guard let ci = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else { print("이미지를 읽을 수 없습니다"); return 1 }
                let results = ImageProcessor.processPages(ci, options: settings.processing, detectDocument: true)
                var jpgs: [URL] = []
                for (k, (cg, rep)) in results.enumerated() {
                    print("보정 \(k + 1)쪽: \(rep.summary)  (기울기 추정 \(String(format: "%.2f", rep.skewDegrees))°)")
                    let png = output.deletingPathExtension().appendingPathExtension(results.count > 1 ? "\(k + 1).png" : "png")
                    if let d = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
                    }
                    if let j = TempStore.saveJPEG(cg) { jpgs.append(j) }
                }
                let texts = try ScanPDFJob.run(imageFiles: jpgs, languages: settings.languages, pageSize: settings.pageSize, output: output,
                                               cancel: CancelToken()) { _, m in print("  · \(m)") }.texts
                print("--- 인식 결과 ---\n" + texts.sorted { $0.key < $1.key }.map { "[\($0.key + 1)쪽]\n\($0.value)" }.joined(separator: "\n"))
            }
            // 검증: 결과 PDF에서 텍스트 추출이 되는지
            if let doc = PDFDocument(url: output) {
                let chars = (0..<doc.pageCount).reduce(0) { $0 + (doc.page(at: $1)?.string?.count ?? 0) }
                print("결과 PDF: \(doc.pageCount)쪽, 추출 가능한 글자 \(chars)자")
            }
            print(String(format: "소요 시간 %.1f초", Date().timeIntervalSince(start)))
            TempStore.cleanUp()
            return 0
        } catch {
            print("오류: \(error.localizedDescription)")
            return 1
        }
    }
}

