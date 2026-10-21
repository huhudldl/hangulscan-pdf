import Foundation
import CoreImage
import Vision

/// 책 모드: 펼친 양쪽 분리 → 쪽별 수평 → 휜 글줄 펴기 → 테두리(배경·책 단면·가운데 그림자) 정리
enum BookProcessor {
    typealias IP = ImageProcessor

    static func process(_ input: CIImage, options: ProcessingOptions, detectDocument: Bool) -> [(CGImage, ProcessReport)] {
        var img = IP.normalized(input)
        var cropped = false
        // 책은 종이와 배경의 밝기 차이가 작은 경우가 많아 기준을 낮춤
        if detectDocument && options.cropDocument,
           let quad = Timing.measure("문서 감지", { IP.detectDocumentQuad(img, minContrast: 0.05) }) {
            img = IP.perspectiveCorrect(img, quad: quad)
            cropped = true
        }
        // 펼친 면 전체의 방향(90°/180°)과 대략적인 수평
        let whole = Timing.measure("펼친 면 수평") { IP.level(img, options: options) }
        img = whole.image

        let halves = Timing.measure("양쪽 분리") { splitSpread(img, languages: options.languages) } ?? [img]
        let split = halves.count == 2

        return halves.compactMap { half -> (CGImage, ProcessReport)? in
            autoreleasepool {
                // 가운데 그림자·고르지 않은 조명을 먼저 걷어냄 (그림자를 글자로 착각하지 않도록)
                var page = Timing.measure("조명 고르게") { flattenLighting(half) }
                var report = ProcessReport()
                report.cropped = cropped
                report.orientationChanged = whole.turn != 0
                report.bookSplit = split
                // 왼쪽·오른쪽 페이지의 기울기는 서로 다를 수 있어 쪽마다 따로 맞춤
                report.skewDegrees = whole.skew
                if options.autoDeskew, let a = IP.estimateSkew(page, languages: options.languages),
                   abs(a) >= 0.1, abs(a) <= 15 {
                    page = IP.rotate(page, degrees: -a)
                    report.skewDegrees += a
                }
                // 두 번까지 반복: 첫 번째에서 남은 휨(특히 접힌 곳 바로 옆)을 다시 재서 다듬음
                // 테두리(접힌 곳 그림자·책 가장자리)를 먼저 걷어내야 휨을 정확히 잴 수 있음
                if let trimmed = Timing.measure("테두리 정리", { trimToContent(page) }) {
                    page = trimmed
                    report.trimmed = true
                }
                // 펴기는 두 번까지: 처음에 남은 휨을 다시 재서 다듬음 (곧아지지 않으면 적용 안 함)
                let iters = Int(ProcessInfo.processInfo.environment["HS_ITER"] ?? "") ?? 2
                for _ in 0..<iters {
                    guard let flat = Timing.measure("휜 줄 펴기", { dewarp(page, languages: options.languages) }) else { break }
                    page = flat
                    report.dewarped = true
                }
                if report.dewarped, let trimmed = trimToContent(page) { page = trimmed }
                if options.enhance { page = IP.enhance(page) }
                guard let cg = IP.cgImage(page, maxDimension: 7200) else { return nil }
                return (cg, report)
            }
        }
    }

    // MARK: - 회색조 버퍼

    struct Gray {
        let w: Int, h: Int
        var px: [UInt8]           // 위쪽 원점, 행 우선
        subscript(x: Int, y: Int) -> UInt8 { px[y * w + x] }

        init?(_ cg: CGImage) {
            w = cg.width; h = cg.height
            px = [UInt8](repeating: 255, count: w * h)
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if !ok { return nil }
        }
    }

    /// Vision 결과(정규화, 아래쪽 원점) → 작은 이미지 픽셀(위쪽 원점) 사각형
    static func pixelRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: r.minX * CGFloat(w), y: (1 - r.maxY) * CGFloat(h), width: r.width * CGFloat(w), height: r.height * CGFloat(h))
    }

    // MARK: - 1. 펼친 양쪽 분리

    /// 가운데 접힌 선(글자가 없는 세로 띠 중 가장 어두운 곳)을 찾아 왼쪽·오른쪽 페이지로 나눈다.
    static func splitSpread(_ img: CIImage, languages: [String]) -> [CIImage]? {
        guard let small = IP.cgImage(img, maxDimension: 1600), small.width > Int(Double(small.height) * 1.05),
              let gray = Gray(small),
              let obs = try? OCREngine.observations(small, languages: languages, languageCorrection: false)
        else { return nil }
        let w = small.width, h = small.height
        var coverage = [Int](repeating: 0, count: w)
        for o in obs {
            let r = pixelRect(o.boundingBox, w, h)
            for x in max(0, Int(r.minX))..<min(w, Int(r.maxX) + 1) { coverage[x] += 1 }
        }
        // 가운데 30~70% 구간에서 글자가 없는 열들의 묶음(띠)
        let lo = w * 3 / 10, hi = w * 7 / 10
        var runs: [Range<Int>] = []
        var start: Int?
        for x in lo..<hi {
            if coverage[x] == 0 { if start == nil { start = x } }
            else if let s = start { runs.append(s..<x); start = nil }
        }
        if let s = start { runs.append(s..<hi) }
        runs = runs.filter { $0.count >= max(3, w / 200) }
        guard let run = runs.min(by: { abs(($0.lowerBound + $0.upperBound) / 2 - w / 2) < abs(($1.lowerBound + $1.upperBound) / 2 - w / 2) })
        else { return nil }

        // 띠 안에서 가장 어두운 열 = 접힌 곳의 그림자
        var spine = (run.lowerBound + run.upperBound) / 2
        var darkest = Int.max
        for x in run {
            var s = 0
            for y in stride(from: h / 10, to: h * 9 / 10, by: 2) { s += Int(gray[x, y]) }
            if s < darkest { darkest = s; spine = x }
        }
        // 양쪽 모두 글줄이 있어야 펼친 면으로 판단
        let leftLines = obs.filter { pixelRect($0.boundingBox, w, h).maxX < CGFloat(spine) }.count
        let rightLines = obs.filter { pixelRect($0.boundingBox, w, h).minX > CGFloat(spine) }.count
        guard leftLines >= 3, rightLines >= 3 else { return nil }

        let sx = img.extent.width / CGFloat(w)
        let cut = CGFloat(spine) * sx
        let left = img.cropped(to: CGRect(x: 0, y: 0, width: cut, height: img.extent.height))
        let right = img.cropped(to: CGRect(x: cut, y: 0, width: img.extent.width - cut, height: img.extent.height))
        return [IP.normalized(left), IP.normalized(right)]
    }

    // MARK: - 2. 휜 글줄 펴기

    struct Sample { let line: Int; let u: Double; let y: Double }

    /// 종이 밝기 기준의 잉크 임계값
    static func inkThreshold(_ g: Gray) -> Int {
        var hist = [Int](repeating: 0, count: 256)
        for v in g.px { hist[Int(v)] += 1 }
        var acc = 0, paper = 255
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc > g.px.count / 2 { paper = v; break } }
        return max(30, paper - 70)
    }

    /// 글줄마다 2글자 폭 구간으로 나눠 '글자 덩어리의 윗선·아랫선 가운데' 높이를 잰다.
    /// (한글은 네모꼴이라 무게중심보다 이 값이 글자 모양에 덜 흔들림)
    /// 휜 줄은 상자가 세로로 길어져 이웃 줄이 섞이므로, 평평한 가운데에서 시작해
    /// 옆 구간의 높이를 따라가며(한 줄 높이 범위 안에서) 바깥쪽으로 추적한다.
    static func measureLines(_ g: Gray, _ boxes: [CGRect], ink: Int) -> (samples: [Sample], lineV: [Double]) {
        let w = g.w, h = g.h
        guard !boxes.isEmpty else { return ([], []) }
        let hMed = Double(boxes.map(\.height).sorted()[boxes.count / 2])   // 보통 글줄 높이
        var samples: [Sample] = [], lineV: [Double] = []

        /// [xa, xb) 구간, 세로 [ya, yb] 범위에서 글자 덩어리 윗선·아랫선 가운데. 실패하면 nil
        func midline(_ xa: Int, _ xb: Int, _ ya: Int, _ yb: Int, lineH: Double) -> Double? {
            let y0 = max(0, ya), y1 = min(h - 1, yb)
            guard y1 > y0, xb > xa else { return nil }
            var rows = [Double](repeating: 0, count: y1 - y0 + 1)
            var total = 0.0
            for y in y0...y1 {
                var sum = 0.0
                for x in xa..<xb { let v = Int(g[x, y]); if v < ink { sum += Double(ink - v) } }
                rows[y - y0] = sum; total += sum
            }
            guard total > lineH * 4 else { return nil }
            var acc = 0.0, top = -1.0, bottom = -1.0
            for (i, v) in rows.enumerated() {
                acc += v
                if top < 0 && acc >= total * 0.08 { top = Double(y0 + i) }
                if bottom < 0 && acc >= total * 0.92 { bottom = Double(y0 + i); break }
            }
            // 잉크가 한 줄 높이보다 훨씬 넓게 퍼지면 그림자·이웃 줄이 섞인 것 → 버림
            guard top >= 0, bottom >= top, bottom - top <= lineH * 1.4 else { return nil }
            return (top + bottom) / 2
        }

        for r in boxes {
            let lineH = min(Double(r.height), hMed * 1.2)
            let slices = max(3, Int(r.width / max(36, CGFloat(lineH) * 1.6)))
            let sw = r.width / CGFloat(slices)
            func span(_ k: Int) -> (Int, Int) {
                (Int(r.minX + CGFloat(k) * sw), min(w, Int(r.minX + CGFloat(k + 1) * sw)))
            }
            var mids = [Double?](repeating: nil, count: slices)
            // 가운데 구간: 상자 가운데를 중심으로 시작
            let c = slices / 2
            let (ca, cb) = span(c)
            guard let start = midline(ca, cb, Int(Double(r.midY) - lineH * 0.8), Int(Double(r.midY) + lineH * 0.8), lineH: lineH)
            else { continue }
            mids[c] = start
            // 양쪽으로 따라가기
            for dir in [-1, 1] {
                var prev = start
                var k = c + dir
                while k >= 0 && k < slices {
                    let (xa, xb) = span(k)
                    if let m = midline(xa, xb, Int(prev - lineH * 0.75), Int(prev + lineH * 0.75), lineH: lineH) {
                        mids[k] = m; prev = m
                    }
                    k += dir
                }
            }
            let got = mids.enumerated().compactMap { k, m -> Sample? in
                guard let m else { return nil }
                let (xa, xb) = span(k)
                return Sample(line: lineV.count, u: Double(xa + xb) / 2 / Double(w), y: m)
            }
            guard got.count >= 3 else { continue }
            samples += got
            lineV.append(got.map(\.y).reduce(0, +) / Double(got.count) / Double(h) - 0.5)
        }
        return (samples, lineV)
    }

    /// 곧은 정도: 글줄마다 직선 추세를 뺀 높이 변화 폭(px)의 중앙값. 작을수록 곧음.
    static func waviness(_ samples: [Sample], lines: Int) -> Double {
        var scores: [Double] = []
        for li in 0..<lines {
            let ss = samples.filter { $0.line == li }
            guard ss.count >= 3 else { continue }
            let n = Double(ss.count), mu = ss.map(\.u).reduce(0, +) / n, my = ss.map(\.y).reduce(0, +) / n
            let b = ss.reduce(0) { $0 + ($1.u - mu) * ($1.y - my) } / max(1e-9, ss.reduce(0) { $0 + ($1.u - mu) * ($1.u - mu) })
            let dev = ss.map { $0.y - (my + b * ($0.u - mu)) }
            scores.append(dev.max()! - dev.min()!)
        }
        guard !scores.isEmpty else { return 0 }
        return scores.sorted()[scores.count / 2]
    }

    /// 책장은 원통처럼 휘므로 모든 글줄이 같은 휨 모양을 공유한다.
    /// 모델: 글줄 i의 높이 y = r_i + B1(u) [+ v_i·B2(u)]  (u = 가로 위치 0~1, v = 세로 위치 -0.5~0.5)
    /// 모든 글줄의 측정값으로 한꺼번에 최소제곱 근사 → 짧은 줄도 긴 줄 덕분에 접힌 곳 근처까지 펴짐.
    /// 편 결과를 다시 재서 실제로 더 곧아졌을 때만 적용한다.
    static func dewarp(_ img: CIImage, languages: [String]) -> CIImage? {
        guard let small = IP.cgImage(img, maxDimension: 1600), let gray = Gray(small),
              let obs = try? OCREngine.observations(small, languages: languages, languageCorrection: false)
        else { return nil }
        let w = gray.w, h = gray.h
        let ink = inkThreshold(gray)
        let boxes = obs.map { pixelRect($0.boundingBox, w, h) }.filter { $0.width > CGFloat(w) * 0.12 && $0.height > 4 }
        let (samples, lineV) = measureLines(gray, boxes, ink: ink)
        let L = lineV.count
        guard L >= 4, samples.count >= 20 else { return nil }
        let before = waviness(samples, lines: L)
        guard before > 2 else { return nil }   // 이미 곧음

        let deg1 = samples.count >= 40 ? 4 : 3
        let deg2 = L >= 10 ? 2 : 0              // 위아래로 달라지는 휨은 글줄이 충분할 때만
        let n = L + deg1 + deg2
        func basis(_ s: Sample) -> [(Int, Double)] {
            var row: [(Int, Double)] = [(s.line, 1)]
            var p = 1.0
            for k in 1...deg1 { p *= s.u; row.append((L + k - 1, p)) }
            p = 1.0
            if deg2 > 0 { for k in 1...deg2 { p *= s.u; row.append((L + deg1 + k - 1, p * lineV[s.line])) } }
            return row
        }
        func solve(_ use: [Sample]) -> [Double]? {
            var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
            for s in use {
                let row = basis(s)
                for (i, a) in row {
                    for (j, b) in row { A[i][j] += a * b }
                    A[i][n] += a * s.y
                }
            }
            for i in 0..<n { A[i][i] += 1e-6 }
            for col in 0..<n {
                guard let piv = (col..<n).max(by: { abs(A[$0][col]) < abs(A[$1][col]) }), abs(A[piv][col]) > 1e-12 else { return nil }
                A.swapAt(col, piv)
                for r in 0..<n where r != col && A[r][col] != 0 {
                    let f = A[r][col] / A[col][col]
                    for c in col...n { A[r][c] -= f * A[col][c] }
                }
            }
            return (0..<n).map { A[$0][n] / A[$0][$0] }
        }
        func predict(_ c: [Double], _ s: Sample) -> Double { basis(s).reduce(0) { $0 + c[$1.0] * $1.1 } }
        guard let first = solve(samples) else { return nil }
        let res = samples.map { abs($0.y - predict(first, $0)) }
        let mad = max(0.5, res.sorted()[res.count / 2])
        guard let coef = solve(zip(samples, res).filter { $0.1 <= 3 * mad }.map { $0.0 }) else { return nil }

        let uMin = samples.map(\.u).min()!, uMax = samples.map(\.u).max()!
        func raw(_ u: Double, _ v: Double) -> Double {
            var p = 1.0, sum = 0.0
            for k in 1...deg1 { p *= u; sum += coef[L + k - 1] * p }
            if deg2 > 0 { p = 1.0; for k in 1...deg2 { p *= u; sum += coef[L + deg1 + k - 1] * p * v } }
            return sum
        }
        /// 측정 범위 밖은 끝 기울기로 짧게(5%) 직선 연장 후 고정
        func bend(_ u: Double, _ v: Double) -> Double {
            if u >= uMin && u <= uMax { return raw(u, v) }
            let end = u < uMin ? uMin : uMax, dir = u < uMin ? -1.0 : 1.0
            let slope = (raw(end, v) - raw(end - dir * 0.01, v)) / (dir * 0.01)
            return raw(end, v) + slope * min(abs(u - end), 0.05) * dir
        }
        let uMid = (uMin + uMax) / 2
        let cap = Double(h) * 0.06            // 지나친 이동 방지
        func d(_ u: Double, _ v: Double) -> Double { max(-cap, min(cap, bend(u, v) - bend(uMid, v))) }

        // 세로 이동량 지도: 열(GX개) × 행(h)
        let GX = 64
        var field = [Float](repeating: 0, count: GX * h)
        let vMin = lineV.min()!, vMax = lineV.max()!
        for g in 0..<GX {
            let u = Double(g) / Double(GX - 1)
            for y in 0..<h {
                let v = min(vMax, max(vMin, Double(y) / Double(h) - 0.5))
                field[y * GX + g] = Float(d(u, v))
            }
        }
        guard let warped = remap(img, field: field, gx: GX, smallW: w, smallH: h) else { return nil }

        // 검증: 같은 글줄 위치에서 다시 재서 실제로 곧아졌는지 확인
        guard let check = IP.cgImage(warped, maxDimension: 1600), let g2 = Gray(check), g2.w == w, g2.h == h else { return nil }
        let (s2, l2) = measureLines(g2, boxes, ink: ink)
        let after = waviness(s2, lines: l2.count)
        if ProcessInfo.processInfo.environment["HS_DEBUG"] != nil {
            print(String(format: "  [휨] 줄 %d개 · 펴기 전 %.1fpx → 후 %.1fpx · u %.2f~%.2f", L, before, after, uMin, uMax))
            print("    이동량(u=0,0.1..1): " + stride(from: 0.0, through: 1.0, by: 0.1).map { String(format: "%5.1f", d($0, 0)) }.joined(separator: " "))
            for li in 0..<min(L, 3) {
                let ss = samples.filter { $0.line == li }
                let m = ss.map(\.y).reduce(0, +) / Double(ss.count)
                print("    줄\(li) 실측: " + ss.map { String(format: "%.2f:%+.1f", $0.u, $0.y - m) }.joined(separator: " "))
            }
        }
        return after < before * 0.8 ? warped : nil
    }

    /// 세로 이동량 지도대로 원본 해상도 이미지를 다시 그린다 (양선형 보간)
    static func remap(_ img: CIImage, field: [Float], gx GX: Int, smallW w: Int, smallH h: Int) -> CIImage? {
        // 원본 해상도에서 다시 그리기 (양선형 보간)
        guard let full = IP.cgImage(img) else { return nil }
        let W = full.width, H = full.height
        let bpr = W * 4
        var src = [UInt8](repeating: 255, count: H * bpr)
        let space = IP.sRGB
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = src.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                                    space: space, bitmapInfo: info) else { return false }
            c.draw(full, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard drawn else { return nil }
        var dst = [UInt8](repeating: 255, count: H * bpr)
        let sxs = Double(w) / Double(W), sys = Double(h) / Double(H)
        let scaleY = Float(Double(H) / Double(h))
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: 8) { part in
                    let ya = H * part / 8, yb = H * (part + 1) / 8
                    for y in ya..<yb {
                        let fy = min(h - 1, Int(Double(y) * sys))
                        let rowBase = fy * GX
                        for x in 0..<W {
                            let gxf = Double(x) * sxs / Double(w - 1) * Double(GX - 1)
                            let g0 = min(GX - 2, Int(gxf)), t = Float(gxf - Double(g0))
                            let dv = (field[rowBase + g0] * (1 - t) + field[rowBase + g0 + 1] * t) * scaleY
                            let syf = Float(y) + dv
                            let fl = syf.rounded(.down)
                            var yi = Int(fl)
                            var fr = syf - fl
                            if yi < 0 { yi = 0; fr = 0 }
                            if yi >= H - 1 { yi = H - 2; fr = 1 }
                            let a = yi * bpr + x * 4, b = a + bpr, od = y * bpr + x * 4
                            for c in 0..<4 {
                                o[od + c] = UInt8(min(255, max(0, Float(s[a + c]) * (1 - fr) + Float(s[b + c]) * fr)))
                            }
                        }
                    }
                }
            }
        }
        let out: CGImage? = dst.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
                      space: space, bitmapInfo: info)?.makeImage()
        }
        return out.map { CIImage(cgImage: $0) }
    }

    /// 진단용: 이미지의 글줄 휨 정도(px, 작은 이미지 기준). 테스트 모드 --bend 에서 사용.
    static func bendScore(_ cg: CGImage, languages: [String]) -> (median: Double, worst: Double)? {
        guard let small = IP.cgImage(CIImage(cgImage: cg), maxDimension: 1600), let g = Gray(small),
              let obs = try? OCREngine.observations(small, languages: languages, languageCorrection: false) else { return nil }
        let boxes = obs.map { pixelRect($0.boundingBox, g.w, g.h) }.filter { $0.width > CGFloat(g.w) * 0.3 }
        let (samples, lineV) = measureLines(g, boxes, ink: inkThreshold(g))
        var per: [Double] = []
        for li in 0..<lineV.count { per.append(waviness(samples.filter { $0.line == li }.map { Sample(line: 0, u: $0.u, y: $0.y) }, lines: 1)) }
        guard !per.isEmpty else { return nil }
        let s = per.sorted()
        return (s[s.count / 2], s[min(s.count - 1, s.count * 9 / 10)])
    }

    // MARK: - 조명 고르게

    /// 글자를 지운 '종이 밝기 지도'를 만들어 원본을 그것으로 나눈다 → 그림자·조명 얼룩 제거.
    static func flattenLighting(_ img: CIImage) -> CIImage {
        let ext = img.extent
        let radius = Float(max(ext.width, ext.height) / 90)          // 글자 굵기보다 충분히 크게
        let small = img.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        // 밝은 값 확장(글자 지우기) → 흐리기 = 종이 밝기
        guard let maxF = CIFilter(name: "CIMorphologyMaximum", parameters: [kCIInputImageKey: small.clampedToExtent(),
                                                                            kCIInputRadiusKey: radius / 4]),
              let opened = maxF.outputImage,
              let blurF = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: opened,
                                                                         kCIInputRadiusKey: radius / 3]),
              let bgSmall = blurF.outputImage
        else { return img }
        let background = bgSmall.transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: ext)
        guard let div = CIFilter(name: "CIDivideBlendMode", parameters: [kCIInputImageKey: background,
                                                                          kCIInputBackgroundImageKey: img]),
              let out = div.outputImage else { return img }
        // 종이 색을 살짝 따뜻한 흰색으로 (완전 흰색보다 눈이 편함)
        return out.cropped(to: ext).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.99, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.98, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.96, w: 0),
        ])
    }

    // MARK: - 3. 테두리 정리

    /// 가장자리에 닿아 있는 어두운 덩어리(배경·책 단면·접힌 곳 그림자·손가락)를 버리고,
    /// 남은 내용(글자·그림)에서 빈 종이가 이어지는 데까지를 쪽으로 보고 자른다.
    static func trimToContent(_ img: CIImage) -> CIImage? {
        guard let small = IP.cgImage(img, maxDimension: 900), let g = Gray(small) else { return nil }
        let w = g.w, h = g.h, n = w * h
        var hist = [Int](repeating: 0, count: 256)
        for v in g.px { hist[Int(v)] += 1 }
        var acc = 0, paper = 255
        for v in stride(from: 255, through: 0, by: -1) { acc += hist[v]; if acc > n / 2 { paper = v; break } }
        let thr = max(25, paper - 45)
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n { mask[i] = Int(g.px[i]) < thr }

        // 연결된 덩어리 찾기 (4방향)
        var label = [Int32](repeating: -1, count: n)
        var stack: [Int] = []
        var minX = 0, minY = 0, maxX = 0, maxY = 0, touches = false, area = 0
        var keep = CGRect.null
        for start in 0..<n where mask[start] && label[start] < 0 {
            label[start] = 1
            stack.append(start)
            minX = w; minY = h; maxX = 0; maxY = 0; touches = false; area = 0
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                area += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touches = true }
                if x > 0, mask[p - 1], label[p - 1] < 0 { label[p - 1] = 1; stack.append(p - 1) }
                if x < w - 1, mask[p + 1], label[p + 1] < 0 { label[p + 1] = 1; stack.append(p + 1) }
                if y > 0, mask[p - w], label[p - w] < 0 { label[p - w] = 1; stack.append(p - w) }
                if y < h - 1, mask[p + w], label[p + w] < 0 { label[p + w] = 1; stack.append(p + w) }
            }
            // 가장자리에 닿은 큰 덩어리 = 배경/단면/그림자 → 버림. 아주 작은 점도 무시
            if touches || area < 3 { continue }
            keep = keep.union(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        guard !keep.isNull, keep.width > CGFloat(w) * 0.2, keep.height > CGFloat(h) * 0.1 else { return nil }

        // 글자 영역에서 바깥으로, 빈 종이(밝은 부분)가 이어지는 데까지 넓힘 → 쪽 모양(세로)을 유지하고
        // 어두운 배경·책 단면·접힌 곳 그림자에서만 멈춤
        let bright = max(0, paper - 30)
        func rowBright(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            var c = 0; for x in x0...x1 where Int(g.px[y * w + x]) >= bright { c += 1 }; return Double(c) / Double(x1 - x0 + 1)
        }
        func colBright(_ x: Int, _ y0: Int, _ y1: Int) -> Double {
            var c = 0; for y in y0...y1 where Int(g.px[y * w + x]) >= bright { c += 1 }; return Double(c) / Double(y1 - y0 + 1)
        }
        var top = Int(keep.minY), bottom = Int(keep.maxY) - 1, left = Int(keep.minX), right = Int(keep.maxX) - 1
        while top > 0 && rowBright(top - 1, left, right) > 0.9 { top -= 1 }
        while bottom < h - 1 && rowBright(bottom + 1, left, right) > 0.9 { bottom += 1 }
        while left > 0 && colBright(left - 1, top, bottom) > 0.9 { left -= 1 }
        while right < w - 1 && colBright(right + 1, top, bottom) > 0.9 { right += 1 }
        // 종이 가장자리 선이 남지 않게 살짝 안쪽으로, 단 글자 둘레 여백은 최소 3% 보장
        let inset = CGFloat(min(w, h)) * 0.01
        let minMargin = CGFloat(min(w, h)) * 0.03
        var paperRect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1).insetBy(dx: inset, dy: inset)
        paperRect = paperRect.union(keep.insetBy(dx: -minMargin, dy: -minMargin))
        var r = paperRect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        // 위쪽 원점 → CI 아래쪽 원점, 원본 해상도로
        let sx = img.extent.width / CGFloat(w), sy = img.extent.height / CGFloat(h)
        r = CGRect(x: r.minX * sx, y: (CGFloat(h) - r.maxY) * sy, width: r.width * sx, height: r.height * sy).integral
        guard r.width * r.height < img.extent.width * img.extent.height * 0.97 else { return nil }
        return IP.normalized(img.cropped(to: r))
    }
}
