import Foundation
import PDFKit
import ImageIO
import CoreImage

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe"), let doc = PDFDocument(url: URL(fileURLWithPath: args[i + 1])) {
            let n = min(doc.pageCount, 4)
            print((0..<n).map { i -> String in
                switch PDFTextProbe.kind(doc.page(at: i)!) {
                case .none: return "\(i + 1)쪽:글자 없음"
                case .ocrLayerOnly: return "\(i + 1)쪽:OCR 글자층"
                case .visibleText: return "\(i + 1)쪽:진짜 글자"
                }
            }.joined(separator: "  "))
            exit(0)
        }
        if let i = args.firstIndex(of: "--dewarp"), let ci = CIImage(contentsOf: URL(fileURLWithPath: args[i + 1])) {
            // 진단용: 휜 줄 펴기만 단독 실행
            let out = BookProcessor.dewarp(ci, languages: ["ko-KR", "en-US"]) ?? ci
            if let cg = ImageProcessor.cgImage(out), let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[i + 2]) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--bend") {
            for path in args[(i + 1)...] {
                if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                   let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                   let r = BookProcessor.bendScore(cg, languages: ["ko-KR", "en-US"]) {
                    print(String(format: "%@  휨 중앙값 %.1fpx, 최악(90%%) %.1fpx", (path as NSString).lastPathComponent, r.median, r.worst))
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--conf"), let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            // 진단용: 줄별 인식 확신도
            for l in (try? OCREngine.recognize(cg, languages: ["ko-KR", "en-US"])) ?? [] {
                let mark = String(Array(l.text).enumerated().map { l.uncertain.contains($0.offset) ? "^" : " " })
                print(String(format: "%@ %.2f  %@", l.needsReview ? "⚠️" : "  ", l.confidence, l.text))
                if !l.uncertain.isEmpty { print("           " + mark + "   후보: " + l.alternatives.joined(separator: " | ")) }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--correcttest"), let doc = PDFDocument(url: URL(fileURLWithPath: args[i + 1])),
           let page = doc.page(at: 0), let img = SearchablePDF.render(page, dpi: 300) {
            // 교정 시험: 1쪽 첫 줄을 바꿔 글자층을 다시 만든다
            var lines = (try? OCREngine.recognize(img, languages: ["ko-KR", "en-US"])) ?? []
            print("원래 첫 줄: \(lines.first?.text ?? "-")")
            lines[0].text = "교정된 첫 줄 테스트"
            let size = CGSize(width: CGFloat(img.width) * 72 / 300, height: CGFloat(img.height) * 72 / 300)
            let out = URL(fileURLWithPath: args[i + 2])
            let w = SearchablePDF.Writer(url: out)!
            w.addPage(image: img, lines: lines, pageSize: size, jpegQuality: 0.9); w.close()
            let d2 = PDFDocument(url: out)!
            print("새 쪽 크기 \(d2.page(at: 0)!.bounds(for: .mediaBox).size) / 원래 \(page.bounds(for: .mediaBox).size)")
            print("'교정된 첫 줄' 검색: \(d2.findString("교정된 첫 줄", withOptions: []).count)건, 예전 첫 줄 검색: \(d2.findString("대한민국 헌법", withOptions: []).count)건")
            exit(0)
        }
        if let i = args.firstIndex(of: "--structure") {
            // 표·문단 인식 시험: --structure <이미지>
            let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil)!
            let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            var finished = false
            Task {
                do {
                    let r = try await StructureJob.recognize(cg, languages: ["ko-KR", "en-US"])
                    print(StructureJob.paragraphText([0: r]))
                } catch { print("오류: \(error)") }
                finished = true
            }
            // 메인 스레드를 막지 않고 돌리며 기다림 (Vision이 메인 큐를 쓸 수 있음)
            let deadline = Date().addingTimeInterval(120)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            if !finished { print("시간 초과") }
            exit(0)
        }
        if let i = args.firstIndex(of: "--compress") {
            // 용량 줄이기 시험: --compress <입력.pdf> <출력 폴더>
            let input = URL(fileURLWithPath: args[i + 1])
            for lv in CompressJob.Level.allCases {
                let out = URL(fileURLWithPath: args[i + 2]).appendingPathComponent("compress_\(lv.rawValue).pdf")
                try? CompressJob.run(input: input, output: out, level: lv, cancel: CancelToken()) { _, _ in }
                let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
                let d = PDFDocument(url: out)
                print(String(format: "%@: %.2fMB, '민주공화국' 검색 %d건", lv.rawValue, Double(size) / 1_048_576,
                             d?.findString("민주공화국", withOptions: []).count ?? -1))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--ai"), let doc = PDFDocument(url: URL(fileURLWithPath: args[i + 1])) {
            // AI 시험: --ai <pdf> [질문]
            let pages = (0..<doc.pageCount).map { ($0, doc.page(at: $0)?.string ?? "") }.filter { !$0.1.isEmpty }
            MainActor.assumeIsolated {
                let ai = DocumentAssistant()
                @MainActor func wait() { while ai.busy { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) } }
                let t = Date()
                ai.summarize(pages); wait()
                print(String(format: "[요약 %.1f초]\n", Date().timeIntervalSince(t)) + ai.output)
                if i + 2 < args.count {
                    ai.ask(args[i + 2], pages: pages); wait()
                    print("[질문] \(args[i + 2])\n" + ai.output)
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--watchtest") {
            // 폴더 자동 OCR 시험: --watchtest <폴더> <초>
            let w = FolderWatcher.shared
            w.testWatch(URL(fileURLWithPath: args[i + 1]))
            let until = Date().addingTimeInterval(Double(args[i + 2]) ?? 30)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
            print("완료 \(w.doneCount), 실패 \(w.failCount)")
            for e in w.log.reversed() { print("  \(e.ok ? "✅" : "❌") \(e.name): \(e.detail)") }
            TempStore.cleanUp()
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest") {
            exit(SelfTest.run(Array(args[(i + 1)...])))
        }
        HangulScanApp.main()
    }
}
