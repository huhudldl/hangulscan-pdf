import SwiftUI
import PDFKit
import CoreImage

/// 용량 줄이기: 검색 글자는 유지한 채 쪽 그림의 해상도·화질을 낮춘다.
enum CompressJob {
    enum Level: String, CaseIterable, Identifiable {
        case normal, small, tiny
        var id: String { rawValue }
        var label: String {
            switch self {
            case .normal: return "보통 — 화면으로 보기 좋은 화질"
            case .small: return "작게 — 메일 첨부용 (컬러, 110dpi)"
            case .tiny: return "아주 작게 — 흑백 문서용 (90dpi)"
            }
        }
    }

    static func run(input: URL, output: URL, level: Level, cancel: CancelToken, progress: ProgressHandler) throws {
        guard let doc = PDFDocument(url: input) else { throw AppError.message("PDF를 읽을 수 없습니다.") }
        if level == .normal {
            // PDFKit 기본 압축: 이미지를 화면용으로 줄이고 JPEG으로 (원래 글자·주석 모두 유지)
            progress(0.5, "줄이는 중…")
            guard doc.write(to: output, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
            else { throw AppError.message("저장에 실패했습니다.") }
            return
        }
        let dpi: CGFloat = level == .small ? 110 : 90
        let quality: CGFloat = level == .small ? 0.6 : 0.5
        let out = PDFDocument()
        var files: [URL] = []
        for i in 0..<doc.pageCount {
            if cancel.isCancelled { throw CancellationError() }
            progress(Double(i) / Double(doc.pageCount), "\(i + 1)/\(doc.pageCount)쪽 줄이는 중…")
            guard let page = doc.page(at: i) else { continue }
            // 원래 글자가 있는 쪽(일반 문서)은 그림으로 바꾸면 오히려 나빠지므로 그대로 둠
            if PDFTextProbe.kind(page) == .visibleText {
                if let c = page.copy() as? PDFPage { out.insert(c, at: out.pageCount) }
                continue
            }
            let made: PDFPage? = autoreleasepool {
                let lines = textLayer(page)
                page.annotations.forEach { $0.shouldDisplay = false }
                defer { page.annotations.forEach { $0.shouldDisplay = true } }
                guard var img = SearchablePDF.render(page, dpi: dpi) else { return nil }
                if level == .tiny, let g = grayscale(img) { img = g }
                let size = CGSize(width: CGFloat(img.width) * 72 / dpi, height: CGFloat(img.height) * 72 / dpi)
                let file = TempStore.newURL("pdf")
                guard let w = SearchablePDF.Writer(url: file) else { return nil }
                w.addPage(image: img, lines: lines, pageSize: size, jpegQuality: quality)
                w.close()
                files.append(file)
                guard let data = try? Data(contentsOf: file, options: .alwaysMapped),
                      let p = PDFDocument(data: data)?.page(at: 0) else { return nil }
                if page.rotation == 0 { page.annotations.forEach { if let c = $0.copy() as? PDFAnnotation { p.addAnnotation(c) } } }
                return p
            }
            if let made { out.insert(made, at: out.pageCount) }
            else if let c = page.copy() as? PDFPage { out.insert(c, at: out.pageCount) }
        }
        out.outlineRoot = doc.outlineRoot
        progress(1, "저장 중…")
        guard out.write(to: output) else { throw AppError.message("저장에 실패했습니다.") }
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// 쪽의 (보이지 않는) 글자층을 줄 단위로 꺼낸다 — 쪽 기준 0~1 좌표 (회전 반영된 모습 기준)
    static func textLayer(_ page: PDFPage) -> [OCRLine] {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        let box = page.bounds(for: .mediaBox)
        let rot = (page.rotation % 360 + 360) % 360
        return all.selectionsByLine().compactMap { sel in
            guard let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let r = sel.bounds(for: page)
            // mediaBox 기준 0~1
            var n = CGRect(x: (r.minX - box.minX) / box.width, y: (r.minY - box.minY) / box.height,
                           width: r.width / box.width, height: r.height / box.height)
            // 쪽 회전을 반영 (그림은 회전된 모습으로 그려지므로)
            switch rot {
            case 90: n = CGRect(x: n.minY, y: 1 - n.maxX, width: n.height, height: n.width)
            case 180: n = CGRect(x: 1 - n.maxX, y: 1 - n.maxY, width: n.width, height: n.height)
            case 270: n = CGRect(x: 1 - n.maxY, y: n.minX, width: n.height, height: n.width)
            default: break
            }
            return OCRLine(text: text, box: n, confidence: 1)
        }
    }

    static func grayscale(_ img: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: img).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        return ImageProcessor.cgImage(ci)
    }
}

/// 용량 줄이기 화면: 단계 고르기 → 결과 용량 확인 → 저장
struct CompressView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var level: CompressJob.Level = .normal
    @State private var working = false
    @State private var message = ""
    @State private var result: URL?
    @State private var original: Int64 = 0
    @State private var reduced: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("용량 줄이기").font(.title3.bold())
            Text("검색·복사용 글자는 그대로 두고 쪽 그림의 화질을 낮춥니다. 원래 글자가 들어 있는 쪽은 그대로 둡니다.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $level) {
                ForEach(CompressJob.Level.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: level) { _, _ in result = nil }

            HStack(spacing: 8) {
                if working { ProgressView().controlSize(.small) }
                if let _ = result {
                    let pct = original > 0 ? 100 - Int(Double(reduced) / Double(original) * 100) : 0
                    Text("\(format(original)) → \(format(reduced))  (\(max(0, pct))% 줄어듦)").font(.headline)
                        .foregroundStyle(pct > 0 ? .green : .secondary)
                } else {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .frame(height: 24)

            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil {
                    Button("줄여 보기") { make() }.buttonStyle(.borderedProminent).disabled(working)
                } else {
                    Button("저장…") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func format(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func make() {
        guard let input = model.fileForJob() else { return }
        working = true
        message = "줄이는 중…"
        let out = TempStore.newURL("pdf")
        let lv = level
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CompressJob.run(input: input, output: out, level: lv, cancel: CancelToken()) { _, m in
                    DispatchQueue.main.async { message = m }
                }
                let a = (try? FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
                let b = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
                DispatchQueue.main.async { working = false; original = a; reduced = b; result = out }
            } catch {
                DispatchQueue.main.async { working = false; message = "실패: \(error.localizedDescription)" }
            }
        }
    }

    private func save() {
        guard let result else { return }
        model.saveCompressed(result)
        dismiss()
    }
}
