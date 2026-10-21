import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// 스캔 이미지 보정: 문서 영역 자르기(원근 보정) → 방향 감지 → 수평(기울기) 보정 → 선명화
enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - 파이프라인

    static func process(_ input: CIImage, options: ProcessingOptions, detectDocument: Bool) -> (CGImage, ProcessReport)? {
        var img = normalized(input)
        var report = ProcessReport()

        if detectDocument && options.cropDocument, let quad = Timing.measure("문서 감지", { detectDocumentQuad(img) }) {
            img = perspectiveCorrect(img, quad: quad)
            report.cropped = true
        }
        if options.autoOrientation || options.autoDeskew {
            let r = Timing.measure("방향·기울기 분석") { level(img, options: options) }
            img = r.image
            report.orientationChanged = r.turn != 0
            report.skewDegrees = r.skew
            // 옆으로 누운 내용을 90° 세우면 원래 여백이 양옆의 큰 띠가 됨 → 그 띠만 잘라
            // 세로 문서는 세로 페이지로 유지
            if abs(r.turn) == 90 { img = trimExcessBands(img) }
        }
        if options.enhance {
            img = enhance(img)
        }
        // 600dpi A4(약 4960×7016)까지 줄이지 않고 유지
        guard let cg = Timing.measure("렌더링", { cgImage(img, maxDimension: 7200) }) else { return nil }
        return (cg, report)
    }

    /// 책 모드면 펼친 면을 두 쪽으로 나눠 여러 장을 돌려준다.
    static func processPages(_ input: CIImage, options: ProcessingOptions, detectDocument: Bool) -> [(CGImage, ProcessReport)] {
        if options.bookMode { return BookProcessor.process(input, options: options, detectDocument: detectDocument) }
        return process(input, options: options, detectDocument: detectDocument).map { [$0] } ?? []
    }

    /// 한 번의 OCR 분석으로 방향(90°/180°)과 기울기를 함께 바로잡는다.
    static func level(_ input: CIImage, options: ProcessingOptions) -> (image: CIImage, turn: Int, skew: Double) {
        var img = input
        guard let small = cgImage(img, maxDimension: 1600) else { return (img, 0, 0) }
        let analysis = analyzeText(small, languages: options.languages)

        // 1) 방향: 글줄이 읽히는 방향으로 판단 (옆으로 누운 글도 Vision이 읽어냄)
        var turn = 0
        if options.autoOrientation {
            if let dom = weightedMedian(analysis.samples), abs(dom) > 45 {
                turn = -Int((dom / 90).rounded()) * 90
            } else if analysis.score < 80 {
                let down = textScore(small, languages: options.languages, orientation: .down)
                if down > analysis.score * 1.5 + 10 { turn = 180 }
            }
            if turn != 0 {
                img = normalized(img.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turn) * .pi / 180)))
            }
        }

        // 2) 기울기: 같은 분석 결과를 회전한 좌표로 바꿔 재사용
        var skew = 0.0
        if options.autoDeskew {
            let found: Double?
            if turn == 180 {
                found = estimateSkew(img, languages: options.languages)   // 뒤집힌 페이지만 다시 분석
            } else {
                let residual = analysis.samples.compactMap { s -> (angle: Double, weight: Double)? in
                    var r = s.angle + Double(turn)
                    while r > 180 { r -= 360 }
                    while r < -180 { r += 360 }
                    return abs(r) < 30 ? (r, s.weight) : nil
                }
                let text = residual.count >= 2 ? weightedMedian(residual) : nil
                let rotatedSmall = turn == 0 ? small : (cgImage(img, maxDimension: 1600) ?? small)
                found = combineSkew(rotatedSmall, textAngle: text, region: rotate(region: analysis.region, by: turn))
            }
            if let a = found, abs(a) >= 0.1, abs(a) <= 25 {
                img = rotate(img, degrees: -a)
                skew = a
            }
        }
        return (img, turn, skew)
    }

    // MARK: - 유틸

    static func normalized(_ img: CIImage) -> CIImage {
        img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    }

    static func cgImage(_ img: CIImage, maxDimension: CGFloat? = nil) -> CGImage? {
        var im = normalized(img)
        if let m = maxDimension {
            let s = m / max(im.extent.width, im.extent.height)
            if s < 1 {
                // 가장자리를 확장한 뒤 축소해야 테두리 픽셀이 투명과 섞여 어두워지지 않음
                let target = CGRect(x: 0, y: 0, width: max(1, floor(im.extent.width * s)), height: max(1, floor(im.extent.height * s)))
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = im.clampedToExtent()
                f.scale = Float(s)
                f.aspectRatio = 1
                im = (f.outputImage ?? im).cropped(to: target)
            }
        }
        let rect = CGRect(x: 0, y: 0, width: floor(im.extent.width), height: floor(im.extent.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return context.createCGImage(im, from: rect, format: .RGBA8, colorSpace: sRGB)
    }

    /// 이미지 중심 기준 회전. 크기는 유지하고 빈 모서리는 흰색으로 채움.
    static func rotate(_ img: CIImage, degrees: Double) -> CIImage {
        let ext = img.extent
        let c = CGPoint(x: ext.midX, y: ext.midY)
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: CGFloat(degrees * .pi / 180))
            .translatedBy(x: -c.x, y: -c.y)
        // 회전으로 생기는 빈 모서리는 이미지 테두리의 대표 색으로 채워 이음새가 보이지 않게 함
        let bg = CIImage(color: borderColor(img)).cropped(to: ext)
        return img.transformed(by: t).composited(over: bg).cropped(to: ext)
    }

    /// 이미지 가장자리(폭의 2%) 픽셀의 대표 색(중앙값)
    static func borderColor(_ img: CIImage) -> CIColor {
        guard let small = cgImage(img, maxDimension: 200),
              let ctx = CGContext(data: nil, width: small.width, height: small.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return .white }
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
        let px = data.assumingMemoryBound(to: UInt8.self)
        let w = small.width, h = small.height, bpr = ctx.bytesPerRow
        let m = max(1, min(w, h) / 50)
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w where x < m || x >= w - m || y < m || y >= h - m {
                let o = y * bpr + x * 4
                rs.append(px[o]); gs.append(px[o + 1]); bs.append(px[o + 2])
            }
        }
        guard !rs.isEmpty else { return .white }
        // 평균 대신 중앙값: 테두리에 걸친 글자·얼룩에 흔들리지 않음
        func median(_ a: [UInt8]) -> Double { Double(a.sorted()[a.count / 2]) / 255 }
        return CIColor(red: median(rs), green: median(gs), blue: median(bs), colorSpace: sRGB) ?? .white
    }

    static func rotate90(_ cg: CGImage, clockwise: Bool) -> CGImage {
        let ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(rotationAngle: clockwise ? -.pi / 2 : .pi / 2))
        return cgImage(ci) ?? cg
    }

    // MARK: - 여백 띠 정리

    /// 글자 영역 바깥의 한쪽 축 여백이 다른 축 여백보다 지나치게 크면(띠) 그 축만 잘라낸다.
    static func trimExcessBands(_ img: CIImage) -> CIImage {
        guard let small = cgImage(img, maxDimension: 1000) else { return img }
        let w = small.width, h = small.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return img }
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self), bpr = ctx.bytesPerRow
        let bg = borderColor(img)
        let bgLum = Int((0.299 * bg.red + 0.587 * bg.green + 0.114 * bg.blue) * 255)

        // 잉크(배경과 확실히 다른 픽셀)가 있는 행·열
        var rowInk = [Int](repeating: 0, count: h), colInk = [Int](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w where abs(Int(px[y * bpr + x]) - bgLum) > 70 {
                rowInk[y] += 1; colInk[x] += 1
            }
        }
        let rowMin = max(1, w / 500), colMin = max(1, h / 500)   // 점 잡티 무시
        guard let top = rowInk.firstIndex(where: { $0 > rowMin }), let bottom = rowInk.lastIndex(where: { $0 > rowMin }),
              let left = colInk.firstIndex(where: { $0 > colMin }), let right = colInk.lastIndex(where: { $0 > colMin })
        else { return img }

        let short = Double(min(w, h))
        let mV = max(Double(min(top, h - 1 - bottom)), short * 0.05)   // 위아래 여백
        let mH = max(Double(min(left, w - 1 - right)), short * 0.05)   // 좌우 여백
        var crop = CGRect(x: 0, y: 0, width: w, height: h)               // 위쪽 원점 좌표
        if Double(min(left, w - 1 - right)) > mV * 2 {
            let x0 = max(0, Double(left) - mV), x1 = min(Double(w), Double(right) + mV)
            crop.origin.x = x0; crop.size.width = x1 - x0
        }
        if Double(min(top, h - 1 - bottom)) > mH * 2 {
            let y0 = max(0, Double(top) - mH), y1 = min(Double(h), Double(bottom) + mH)
            crop.origin.y = y0; crop.size.height = y1 - y0
        }
        guard crop.width * crop.height < Double(w * h) * 0.85 else { return img }

        // 작은 이미지 좌표 → 원본 좌표 (CI는 아래쪽 원점)
        let sx = img.extent.width / CGFloat(w), sy = img.extent.height / CGFloat(h)
        let rect = CGRect(x: crop.minX * sx, y: (CGFloat(h) - crop.maxY) * sy,
                          width: crop.width * sx, height: crop.height * sy).integral
        return normalized(img.cropped(to: rect))
    }

    // MARK: - 문서 영역 감지 + 원근 보정

    static func detectDocumentQuad(_ img: CIImage, minContrast: Double = 0.12) -> Quad? {
        guard let small = cgImage(img, maxDimension: 1024) else { return nil }
        let handler = VNImageRequestHandler(cgImage: small, options: [:])
        let seg = VNDetectDocumentSegmentationRequest()
        let rect = VNDetectRectanglesRequest()
        rect.maximumObservations = 1
        rect.minimumSize = 0.3
        rect.minimumConfidence = 0.6
        rect.quadratureTolerance = 25
        rect.minimumAspectRatio = 0.3
        try? handler.perform([seg, rect])
        let candidates: [VNRectangleObservation] = (seg.results ?? []) + (rect.results ?? [])
        for o in candidates where o.confidence >= 0.5 {
            let q = Quad(o)
            // 너무 작거나 이미지 전체(이미 평평한 스캔)면 건너뜀.
            // 배경이 종이보다 확실히 어두울 때만 자름 → 흰 배경 스캔의 여백은 보존
            if q.area > 0.12 && q.area < 0.95, paperContrast(small, quad: q) > minContrast { return q }
        }
        return nil
    }

    /// (사각형 안쪽 평균 밝기) - (바깥쪽 평균 밝기), 0~1
    static func paperContrast(_ cg: CGImage, quad: Quad) -> Double {
        let w = 160, h = 160
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        let path = CGMutablePath()
        path.addLines(between: quad.points.map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) })
        path.closeSubpath()
        var inSum = 0.0, inN = 0.0, outSum = 0.0, outN = 0.0
        for row in 0..<h {
            for x in 0..<w {
                let v = Double(px[row * ctx.bytesPerRow + x]) / 255
                if path.contains(CGPoint(x: Double(x) + 0.5, y: Double(h - 1 - row) + 0.5)) {
                    inSum += v; inN += 1
                } else {
                    outSum += v; outN += 1
                }
            }
        }
        guard inN > 0, outN > 0 else { return 0 }
        return inSum / inN - outSum / outN
    }

    static func perspectiveCorrect(_ img: CIImage, quad: Quad) -> CIImage {
        let w = img.extent.width, h = img.extent.height
        // 종이 테두리에 배경이 한 줄 남지 않도록 중심 쪽으로 0.6% 들여 자름
        let cx = quad.points.reduce(0) { $0 + $1.x } / 4, cy = quad.points.reduce(0) { $0 + $1.y } / 4
        func p(_ n: CGPoint) -> CGPoint {
            let k: CGFloat = 0.012
            return CGPoint(x: (n.x + (cx - n.x) * k) * w, y: (n.y + (cy - n.y) * k) * h)
        }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = img
        f.topLeft = p(quad.topLeft)
        f.topRight = p(quad.topRight)
        f.bottomRight = p(quad.bottomRight)
        f.bottomLeft = p(quad.bottomLeft)
        guard let out = f.outputImage else { return img }
        return normalized(out)
    }

    // MARK: - 글줄 분석 (방향 + 기울기 공통)

    struct TextAnalysis {
        var samples: [(angle: Double, weight: Double)] = []   // 글줄 읽는 방향 각도(전체 범위)
        var region: CGRect = .null                              // 글자 영역(정규화)
        var score: Double = 0                                   // 인식 품질 점수
    }

    static func analyzeText(_ cg: CGImage, languages: [String]) -> TextAnalysis {
        var a = TextAnalysis()
        guard let obs = try? OCREngine.observations(cg, languages: languages, languageCorrection: false) else { return a }
        let W = Double(cg.width), H = Double(cg.height)
        for o in obs {
            let dx = (Double(o.bottomRight.x - o.bottomLeft.x) + Double(o.topRight.x - o.topLeft.x)) / 2 * W
            let dy = (Double(o.bottomRight.y - o.bottomLeft.y) + Double(o.topRight.y - o.topLeft.y)) / 2 * H
            let len = hypot(dx, dy)
            if len > 40 { a.samples.append((atan2(dy, dx) * 180 / .pi, len)) }
            a.region = a.region.union(o.boundingBox)
            if let c = o.topCandidates(1).first { a.score += Double(c.confidence) * Double(c.string.count) }
        }
        return a
    }

    static func textScore(_ cg: CGImage, languages: [String], orientation: CGImagePropertyOrientation) -> Double {
        let obs = (try? OCREngine.observations(cg, languages: languages, orientation: orientation,
                                                languageCorrection: false)) ?? []
        return obs.reduce(0) { acc, ob in
            guard let c = ob.topCandidates(1).first else { return acc }
            return acc + Double(c.confidence) * Double(c.string.count)
        }
    }

    /// 정규화 사각형을 이미지 회전(반시계 turn도, 90의 배수)에 맞게 변환
    static func rotate(region r: CGRect, by turn: Int) -> CGRect {
        guard !r.isNull else { return r }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]
        let mapped: [CGPoint] = corners.map { p in
            switch (turn % 360 + 360) % 360 {
            case 90: return CGPoint(x: 1 - p.y, y: p.x)
            case 270: return CGPoint(x: p.y, y: 1 - p.x)
            case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
            default: return p
            }
        }
        return CGRect(x: min(mapped[0].x, mapped[1].x), y: min(mapped[0].y, mapped[1].y),
                      width: abs(mapped[0].x - mapped[1].x), height: abs(mapped[0].y - mapped[1].y))
    }

    static func weightedMedian(_ samples: [(angle: Double, weight: Double)]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.angle < $1.angle }
        let total = sorted.reduce(0) { $0 + $1.weight }
        var acc = 0.0
        for s in sorted {
            acc += s.weight
            if acc >= total / 2 { return s.angle }
        }
        return sorted.last?.angle
    }

    // MARK: - 기울기(수평) 추정

    /// 반환값: 문서가 반시계 방향으로 기울어진 각도(도). 보정하려면 -각도만큼 회전.
    static func estimateSkew(_ img: CIImage, languages: [String]) -> Double? {
        guard let small = cgImage(img, maxDimension: 1600) else { return nil }
        let a = analyzeText(small, languages: languages)
        let flat = a.samples.filter { abs($0.angle) < 30 }
        return combineSkew(small, textAngle: flat.count >= 2 ? weightedMedian(flat) : nil, region: a.region)
    }

    /// 글줄 추정치를 글자 영역 안 투영 분석으로 정밀화. 1° 넘게 어긋나면 글줄 값을 신뢰.
    static func combineSkew(_ small: CGImage, textAngle: Double?, region: CGRect) -> Double? {
        guard let text = textAngle else { return projectionSkew(small, hint: nil, region: nil) }
        if let refined = projectionSkew(small, hint: text, region: region.isNull ? nil : region),
           abs(refined - text) <= 1 { return refined }
        return text
    }

    /// 2단계: 투영 프로파일 분석 — 어두운 픽셀을 각도별로 가로 투영해 줄이 가장 선명해지는 각도를 찾음.
    /// 글자가 없는 문서(표, 도면)에도 동작하며, 글줄 추정치가 있으면 그 주변을 정밀 탐색.
    static func projectionSkew(_ cg: CGImage, hint: Double?, region: CGRect?) -> Double? {
        let maxDim = 1000.0
        let s = min(1, maxDim / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * s)), h = max(1, Int(Double(cg.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bpr = ctx.bytesPerRow
        let px = data.assumingMemoryBound(to: UInt8.self)

        // 가장자리(스캐너 그림자 등)는 제외, 글자 영역이 주어지면 그 안만 사용
        var x0 = w * 3 / 100, x1 = w - x0, y0 = h * 3 / 100, y1 = h - y0   // y는 위쪽 원점(행)
        if let r = region, !r.isNull {
            x0 = max(x0, Int(r.minX * CGFloat(w))); x1 = min(x1, Int(r.maxX * CGFloat(w)))
            y0 = max(y0, Int((1 - r.maxY) * CGFloat(h))); y1 = min(y1, Int((1 - r.minY) * CGFloat(h)))
        }
        guard x1 > x0, y1 > y0 else { return nil }
        var sum = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += Int(px[y * bpr + x]) } }
        let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
        let threshold = UInt8(max(40, min(170, mean * 0.7)))
        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity(100_000); ys.reserveCapacity(100_000)
        for row in y0..<y1 {
            let yUp = Float(h - 1 - row)
            let base = row * bpr
            for x in x0..<x1 where px[base + x] < threshold {
                xs.append(Float(x)); ys.append(yUp)
            }
        }
        guard xs.count >= 300 else { return nil }
        if xs.count > 160_000 {
            let stride = xs.count / 160_000 + 1
            xs = Swift.stride(from: 0, to: xs.count, by: stride).map { xs[$0] }
            ys = Swift.stride(from: 0, to: ys.count, by: stride).map { ys[$0] }
        }

        let offset = Float(w + h)
        let binCount = 2 * (w + h) + 2
        var hist = [Int32](repeating: 0, count: binCount)
        func score(_ deg: Double) -> Double {
            let r = Float(deg * .pi / 180)
            let sn = sinf(r), cs = cosf(r)
            for i in 0..<hist.count { hist[i] = 0 }
            for i in 0..<xs.count {
                let yp = -xs[i] * sn + ys[i] * cs + offset
                hist[Int(yp)] += 1
            }
            var sc = 0.0
            for c in hist where c > 0 { sc += Double(c) * Double(c) }
            return sc
        }
        func search(from a: Double, to b: Double, step: Double) -> (Double, Double) {
            var best = (a, -1.0)
            var x = a
            while x <= b + 1e-9 {
                let sc = score(x)
                if sc > best.1 { best = (x, sc) }
                x += step
            }
            return best
        }

        let coarse: (Double, Double)
        if let hint {
            coarse = search(from: hint - 2, to: hint + 2, step: 0.25)
        } else {
            coarse = search(from: -15, to: 15, step: 0.5)
            // 텍스트 단서 없이 찾은 경우: 0°보다 확실히 나을 때만 채택
            if coarse.1 < score(0) * 1.05 { return 0 }
        }
        let fine = search(from: coarse.0 - 0.3, to: coarse.0 + 0.3, step: 0.05)
        return fine.0
    }

    // MARK: - 선명화

    static func enhance(_ img: CIImage) -> CIImage {
        if let f = CIFilter(name: "CIDocumentEnhancer") {
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(1.0, forKey: "inputAmount")
            if let out = f.outputImage { return out.cropped(to: img.extent) }
        }
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = 0
        f.contrast = 1.3
        f.brightness = 0.05
        return f.outputImage ?? img
    }
}
