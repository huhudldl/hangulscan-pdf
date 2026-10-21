import Foundation
import Vision
import PDFKit

/// macOS 26 문서 구조 인식으로 표·문단을 찾아낸다 (기기 안에서 처리).
enum StructureJob {
    struct PageResult {
        var paragraphs: [String] = []      // 표 밖의 문단 (읽는 순서)
        var tables: [[[String]]] = []      // 표 → 행 → 칸
        var blocks: [Block] = []           // 문단과 표를 위에서 아래 순서로
    }

    enum Block {
        case paragraph(String)
        case table(Int)                    // tables 안의 번호
    }

    private static func rect(_ r: NormalizedRect) -> CGRect {
        CGRect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }

    static func recognize(_ image: CGImage, languages: [String]) async throws -> PageResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.textRecognitionOptions.useLanguageCorrection = true
        let observations = try await request.perform(on: image)
        var result = PageResult()
        var placed: [(top: CGFloat, block: Block)] = []
        for obs in observations {
            let doc = obs.document
            let tableRects = doc.tables.map { rect($0.boundingRegion.boundingBox) }
            for (k, table) in doc.tables.enumerated() {
                result.tables.append(grid(table))
                placed.append((tableRects[k].maxY, .table(result.tables.count - 1)))
            }
            for p in doc.paragraphs {
                let text = p.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let r = rect(p.boundingRegion.boundingBox)
                // 표 안의 칸 글자는 문단에서 빼고 표로만 내보냄
                if tableRects.contains(where: { $0.insetBy(dx: -0.005, dy: -0.005).contains(CGPoint(x: r.midX, y: r.midY)) }) { continue }
                result.paragraphs.append(text)
                placed.append((r.maxY, .paragraph(text)))
            }
        }
        // 위(값이 큰 쪽)부터 아래로
        result.blocks = placed.sorted { $0.top > $1.top }.map(\.block)
        return result
    }

    /// 병합된 칸까지 고려해 행·열 격자로 펼친다 (병합 칸 글자는 첫 칸에만)
    static func grid(_ table: DocumentObservation.Container.Table) -> [[String]] {
        let cells = table.rows.flatMap { $0 }
        let rowCount = (cells.map(\.rowRange.upperBound).max() ?? -1) + 1
        let colCount = (cells.map(\.columnRange.upperBound).max() ?? -1) + 1
        guard rowCount > 0, colCount > 0 else { return [] }
        var g = [[String]](repeating: [String](repeating: "", count: colCount), count: rowCount)
        for c in cells {
            let text = c.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            g[c.rowRange.lowerBound][c.columnRange.lowerBound] = text
        }
        return g
    }

    /// 문서의 모든 쪽을 그림으로 그려 구조를 인식한다
    static func run(pdf: URL, languages: [String], dpi: CGFloat = 220,
                    cancel: CancelToken, progress: @escaping ProgressHandler) async throws -> [Int: PageResult] {
        guard let doc = PDFDocument(url: pdf) else { throw AppError.message("PDF를 읽을 수 없습니다.") }
        var out: [Int: PageResult] = [:]
        for i in 0..<doc.pageCount {
            if cancel.isCancelled { throw CancellationError() }
            progress(Double(i) / Double(doc.pageCount), "\(i + 1)/\(doc.pageCount)쪽 표·문단 찾는 중…")
            guard let page = doc.page(at: i), let img = autoreleasepool(invoking: { SearchablePDF.render(page, dpi: dpi) }) else { continue }
            out[i] = try await recognize(img, languages: languages)
        }
        progress(1, "정리 중…")
        return out
    }

    // MARK: 저장 형식

    /// 엑셀에서 한글이 깨지지 않도록 UTF-8 BOM을 붙인 CSV
    static func csv(_ rows: [[String]]) -> Data {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let body = rows.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
    }

    /// 문단은 빈 줄로 나누고, 표는 칸을 탭으로 구분해 제자리에 넣은 텍스트
    static func paragraphText(_ pages: [Int: PageResult]) -> String {
        pages.sorted { $0.key < $1.key }.map { i, r in
            let body = r.blocks.map { b -> String in
                switch b {
                case .paragraph(let t): return t
                case .table(let k): return "[표]\n" + r.tables[k].map { $0.joined(separator: "\t") }.joined(separator: "\n")
                }
            }.joined(separator: "\n\n")
            return "─── \(i + 1)쪽 ───\n\n" + body
        }.joined(separator: "\n\n\n") + "\n"
    }
}
