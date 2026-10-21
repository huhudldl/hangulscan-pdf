import Foundation
import CoreGraphics
import Vision

/// Apple Vision 프레임워크 기반 한국어 OCR (온디바이스, 인터넷 불필요)
enum OCREngine {
    static func observations(_ image: CGImage,
                             languages: [String],
                             orientation: CGImagePropertyOrientation = .up,
                             languageCorrection: Bool = true) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate   // 한국어는 accurate 모드에서만 지원
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    static func recognize(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
        try observations(image, languages: languages).compactMap { obs in
            let cands = obs.topCandidates(5)
            guard let c = cands.first else { return nil }
            let text = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var line = OCRLine(text: text, box: obs.boundingBox, confidence: c.confidence)
            let (pos, alts) = ambiguity(text, cands.dropFirst().map(\.string))
            line.uncertain = pos
            line.alternatives = alts
            return line
        }
    }

    /// 다른 후보와 비교해 '글자가 바뀌어' 읽힌 위치를 찾는다.
    /// 띄어쓰기만 다르거나 글자가 빠진 후보는 흔한 잡음이라 무시하고, 길이가 같은데 1~2글자가 다른 후보만 본다.
    static func ambiguity(_ top: String, _ others: [String]) -> (positions: [Int], alternatives: [String]) {
        let topChars = Array(top)
        let topIdx = topChars.indices.filter { !topChars[$0].isWhitespace }   // 공백 뺀 글자 → 원래 위치
        let a = topIdx.map { topChars[$0] }
        var positions = Set<Int>()
        var alts: [String] = []
        for o in others {
            let b = Array(o.trimmingCharacters(in: .whitespacesAndNewlines)).filter { !$0.isWhitespace }
            guard b.count == a.count else { continue }
            let diff = a.indices.filter { a[$0] != b[$0] }
            guard !diff.isEmpty, diff.count <= 2 else { continue }
            diff.forEach { positions.insert(topIdx[$0]) }
            let alt = o.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alts.contains(alt) && alts.count < 3 { alts.append(alt) }
        }
        return (positions.sorted(), alts)
    }

    /// 줄들을 읽는 순서(위→아래, 왼쪽→오른쪽)로 정리한 일반 텍스트
    static func layoutText(_ lines: [OCRLine]) -> String {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[OCRLine]] = []
        for line in sorted {
            if let ref = rows.last?.first {
                let overlap = min(ref.box.maxY, line.box.maxY) - max(ref.box.minY, line.box.minY)
                if overlap > 0.5 * min(ref.box.height, line.box.height) {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }
}
