import Foundation
import CoreGraphics
import CoreImage
import Vision

/// OCR로 인식된 한 줄. box는 이미지 기준 정규화 좌표(0~1, 원점 왼쪽 아래).
struct OCRLine {
    var text: String
    var box: CGRect
    var confidence: Float
    /// 다른 후보와 글자가 다르게 읽힌 위치(text 안의 글자 순번) — 교정 화면에서 표시
    var uncertain: [Int] = []
    /// 글자가 바뀌어 읽힌 다른 후보들 (교정 화면에서 눌러서 바로 바꾸기)
    var alternatives: [String] = []

    /// 사람이 확인해 볼 만한 줄인가
    var needsReview: Bool { confidence < 0.99 || !uncertain.isEmpty }
}

/// 정규화 좌표(원점 왼쪽 아래)의 사각형 네 꼭짓점.
struct Quad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    init(_ o: VNRectangleObservation) {
        topLeft = o.topLeft
        topRight = o.topRight
        bottomRight = o.bottomRight
        bottomLeft = o.bottomLeft
    }

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// 신발끈 공식으로 구한 넓이 (이미지 전체 = 1)
    var area: CGFloat {
        let p = points
        var s: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    func maxDistance(to o: Quad) -> CGFloat {
        zip(points, o.points).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }

    /// 문서 위/아래 변의 평균 기울기(도). 양수 = 반시계 방향으로 기울어짐.
    func tiltDegrees(width: Int, height: Int) -> Double {
        let w = Double(width), h = Double(height)
        let a1 = atan2(Double(topRight.y - topLeft.y) * h, Double(topRight.x - topLeft.x) * w)
        let a2 = atan2(Double(bottomRight.y - bottomLeft.y) * h, Double(bottomRight.x - bottomLeft.x) * w)
        return (a1 + a2) / 2 * 180 / .pi
    }
}

struct ProcessingOptions {
    var languages: [String] = ["ko-KR", "en-US"]
    var autoDeskew = true
    var autoOrientation = true
    var cropDocument = true
    var enhance = false
    var bookMode = false
}

struct ProcessReport {
    var skewDegrees: Double = 0
    var orientationChanged = false
    var cropped = false
    var bookSplit = false
    var dewarped = false
    var trimmed = false

    var summary: String {
        var parts: [String] = []
        if bookSplit { parts.append("양쪽 분리") }
        if cropped { parts.append("문서 영역 자르기") }
        if dewarped { parts.append("휜 줄 펴기") }
        if trimmed { parts.append("테두리 정리") }
        if orientationChanged { parts.append("방향 보정") }
        if abs(skewDegrees) >= 0.1 {
            parts.append(String(format: "수평 보정 %+.1f°", -skewDegrees))
        } else {
            parts.append("수평 양호")
        }
        return parts.joined(separator: " · ")
    }
}

/// 결과 PDF의 쪽 크기. 스캔마다 잘리는 영역이 달라도 모든 쪽을 같은 크기로 맞춘다.
enum PageSizeMode: String, CaseIterable, Identifiable, Codable {
    case auto, a4, b5, letter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "자동 (모든 쪽 같은 크기)"
        case .a4: return "A4"
        case .b5: return "B5 (책)"
        case .letter: return "Letter"
        }
    }
    /// 세로 방향 크기(pt). 자동은 nil
    var portraitSize: CGSize? {
        switch self {
        case .auto: return nil
        case .a4: return CGSize(width: 595.3, height: 841.9)
        case .b5: return CGSize(width: 515.9, height: 728.5)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }
}

struct OCRSettings: Equatable, Codable {
    var english = true
    var japanese = false
    var chinese = false
    var autoDeskew = true
    var autoOrientation = true
    var cropDocument = true
    var enhance = false
    var skipTextPages = true
    var bookMode = false
    var dpi: Double = 300
    var pageSize: PageSizeMode = .auto

    var languages: [String] {
        var l = ["ko-KR"]
        if english { l.append("en-US") }
        if japanese { l.append("ja-JP") }
        if chinese { l.append("zh-Hans") }
        return l
    }

    init() {}

    /// 저장된 값에 없는 항목(새로 생긴 설정)은 기본값으로 채워 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OCRSettings()
        english = try c.decodeIfPresent(Bool.self, forKey: .english) ?? d.english
        japanese = try c.decodeIfPresent(Bool.self, forKey: .japanese) ?? d.japanese
        chinese = try c.decodeIfPresent(Bool.self, forKey: .chinese) ?? d.chinese
        autoDeskew = try c.decodeIfPresent(Bool.self, forKey: .autoDeskew) ?? d.autoDeskew
        autoOrientation = try c.decodeIfPresent(Bool.self, forKey: .autoOrientation) ?? d.autoOrientation
        cropDocument = try c.decodeIfPresent(Bool.self, forKey: .cropDocument) ?? d.cropDocument
        enhance = try c.decodeIfPresent(Bool.self, forKey: .enhance) ?? d.enhance
        skipTextPages = try c.decodeIfPresent(Bool.self, forKey: .skipTextPages) ?? d.skipTextPages
        bookMode = try c.decodeIfPresent(Bool.self, forKey: .bookMode) ?? d.bookMode
        dpi = try c.decodeIfPresent(Double.self, forKey: .dpi) ?? d.dpi
        pageSize = (try? c.decodeIfPresent(PageSizeMode.self, forKey: .pageSize)) ?? d.pageSize
    }

    // MARK: 저장 (앱을 다시 켜도 설정 유지)
    private static let key = "ocrSettings"
    static func load() -> OCRSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(OCRSettings.self, from: d) else { return OCRSettings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    var processing: ProcessingOptions {
        ProcessingOptions(languages: languages, autoDeskew: autoDeskew,
                          autoOrientation: autoOrientation, cropDocument: cropDocument,
                          enhance: enhance, bookMode: bookMode)
    }
}

/// 스캔 한 장. 이미지는 디스크에 두고 메모리에는 작은 미리보기만 둔다.
struct ScanPage: Identifiable {
    let id = UUID()
    let sourceURL: URL      // 원본(가져온 파일 또는 촬영 저장본) — 다시 보정할 때 사용
    var imageURL: URL       // 보정된 이미지(JPEG)
    var thumbnail: CGImage  // 화면 표시용
    var report: ProcessReport
}

enum ScanInput {
    case file(URL)
    case image(CIImage)
}

final class CancelToken {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [OutlineItem]?
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
