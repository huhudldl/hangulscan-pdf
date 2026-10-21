import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// 이미지 위에 보이지 않는 텍스트 층을 얹어 검색·복사 가능한 PDF를 만든다.
enum SearchablePDF {
    /// 페이지를 하나씩 파일에 바로 써 나간다 (전체 PDF를 메모리에 들고 있지 않음).
    final class Writer {
        private let ctx: CGContext
        private(set) var pageCount = 0

        init?(url: URL) {
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            let info = [kCGPDFContextCreator: "한글스캔 PDF"] as CFDictionary
            guard let c = CGContext(url as CFURL, mediaBox: &box, info) else { return nil }
            ctx = c
        }

        /// 디스크의 JPEG을 다시 압축하지 않고 그대로 넣는다 (화질 손실·시간 없음)
        @discardableResult
        func addPage(jpegFile url: URL, lines: [OCRLine], pageSize: CGSize) -> [OCRLine] {
            guard let provider = CGDataProvider(url: url as CFURL),
                  let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                    intent: .defaultIntent) else { return [] }
            return addPage(prepared: img, lines: lines, pageSize: pageSize)
        }

        /// 반환값: 쪽 전체 기준(0~1) 좌표로 바꾼 줄 정보 — 교정 화면에서 사용
        @discardableResult
        func addPage(image: CGImage, lines: [OCRLine], pageSize: CGSize, jpegQuality: CGFloat = 0.82) -> [OCRLine] {
            addPage(prepared: SearchablePDF.jpegImage(image, quality: jpegQuality) ?? image, lines: lines, pageSize: pageSize)
        }

        /// 이미지를 pageSize 쪽 안에 비율을 유지해 가운데 놓는다. 남는 여백은 이미지 테두리 색(종이 색)으로 채움.
        /// 내용이 가로면 같은 크기의 가로 쪽을 쓴다.
        private func addPage(prepared img: CGImage, lines: [OCRLine], pageSize: CGSize) -> [OCRLine] {
            let (page, rect) = SearchablePDF.placement(imagePixels: CGSize(width: img.width, height: img.height), page: pageSize)
            var box = CGRect(origin: .zero, size: page)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            if rect.width < page.width - 0.5 || rect.height < page.height - 0.5 {
                let c = ImageProcessor.borderColor(CIImage(cgImage: img))
                ctx.setFillColor(CGColor(red: c.red, green: c.green, blue: c.blue, alpha: 1))
                ctx.fill(box)
            }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: rect)
            SearchablePDF.drawInvisibleText(lines, in: ctx, imageRect: rect)
            ctx.endPDFPage()
            pageCount += 1
            return lines.map { l in
                var o = l
                o.box = CGRect(x: (rect.minX + l.box.minX * rect.width) / page.width,
                               y: (rect.minY + l.box.minY * rect.height) / page.height,
                               width: l.box.width * rect.width / page.width,
                               height: l.box.height * rect.height / page.height)
                return o
            }
        }

        func close() { ctx.closePDF() }
    }

    /// 글자 상자(이미지 기준 0~1)를 쪽 위 이미지가 놓인 영역(imageRect)으로 옮겨 보이지 않게 쓴다
    static func drawInvisibleText(_ lines: [OCRLine], in ctx: CGContext, imageRect ir: CGRect) {
        let W = ir.width, H = ir.height
        for l in lines {
            let r = CGRect(x: ir.minX + l.box.minX * W, y: ir.minY + l.box.minY * H,
                           width: l.box.width * W, height: l.box.height * H)
            guard r.width > 1, r.height > 1, !l.text.isEmpty else { continue }
            let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, max(1, r.height), nil)
            let attr = NSAttributedString(string: l.text,
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            guard tw > 0, ascent + descent > 0 else { continue }

            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = .identity
            ctx.translateBy(x: r.minX, y: r.minY)
            ctx.scaleBy(x: r.width / tw, y: r.height / (ascent + descent))
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// JPEG로 압축된 CGImage (PDF 안에 DCT로 그대로 들어가 용량이 작아짐)
    static func jpegImage(_ image: CGImage, quality: CGFloat) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 스캔 이미지 픽셀 크기 → PDF 페이지 크기(긴 변 = A4 세로 842pt)
    /// 쪽 방향을 내용 방향(세로/가로)에 맞추고, 그 안에 이미지를 비율 유지로 가운데 배치
    static func placement(imagePixels px: CGSize, page: CGSize) -> (page: CGSize, rect: CGRect) {
        var page = page
        if (px.width > px.height) != (page.width > page.height) { page = CGSize(width: page.height, height: page.width) }
        let s = min(page.width / px.width, page.height / px.height)
        let w = px.width * s, h = px.height * s
        return (page, CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h))
    }

    /// 여러 장의 비율 중간값으로 통일 쪽 크기(세로, 긴 변 842pt)를 정한다
    static func uniformSize(forPixels sizes: [CGSize]) -> CGSize {
        let ratios = sizes.filter { $0.width > 0 && $0.height > 0 }
            .map { max($0.width, $0.height) / min($0.width, $0.height) }.sorted()
        let r = ratios.isEmpty ? 841.9 / 595.3 : ratios[ratios.count / 2]
        return CGSize(width: 841.9 / r, height: 841.9)
    }

    static func pageSize(forPixels px: CGSize) -> CGSize {
        let s = 842.0 / Double(max(px.width, px.height))
        return CGSize(width: Double(px.width) * s, height: Double(px.height) * s)
    }

    /// PDF 페이지를 지정한 해상도의 이미지로 렌더링 (페이지 회전 반영)
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        var size = bounds.size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let scale = dpi / 72
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageProcessor.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
