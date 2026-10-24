import AppKit
// PDF 문서 아이콘 만들기: swift make_doc_icon.swift <출력 iconset 폴더> <앱 아이콘 이미지>
// 오른쪽 위가 접힌 흰 종이 + 가운데 앱 아이콘 + 아래 빨간 'PDF' — Finder에서 PDF 파일 아이콘으로 쓰임
let out = CommandLine.arguments[1]
let logo = CommandLine.arguments.count > 2 ? NSImage(contentsOfFile: CommandLine.arguments[2]) : nil
let sizes = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]

for (name, px) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high

    // 종이 영역 (세로로 긴 문서 모양)
    let pw = s * 0.70, ph = s * 0.88
    let page = CGRect(x: (s - pw) / 2, y: (s - ph) / 2, width: pw, height: ph)
    let fold = pw * 0.26, r = s * 0.03

    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX + r, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX - r, y: page.minY))
    path.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + r), control: CGPoint(x: page.maxX, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.addLine(to: CGPoint(x: page.minX + r, y: page.maxY))
    path.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - r), control: CGPoint(x: page.minX, y: page.maxY))
    path.addLine(to: CGPoint(x: page.minX, y: page.minY + r))
    path.addQuadCurve(to: CGPoint(x: page.minX + r, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
    path.closeSubpath()

    // 그림자 + 흰 종이
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedWhite: 0.995, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.78, alpha: 1).cgColor)
    ctx.setLineWidth(max(0.5, s * 0.004))
    ctx.strokePath()

    // 접힌 귀퉁이
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    ear.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + r))
    ear.addQuadCurve(to: CGPoint(x: page.maxX - fold + r, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    ear.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    ear.closeSubpath()
    ctx.addPath(ear)
    ctx.setFillColor(NSColor(calibratedWhite: 0.88, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.addPath(ear)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.72, alpha: 1).cgColor)
    ctx.strokePath()

    // 가운데 앱 로고
    if let logo, px >= 32 {
        let lw = pw * 0.78
        let lr = CGRect(x: page.midX - lw / 2, y: page.minY + ph * 0.30, width: lw, height: lw)
        logo.draw(in: lr, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // 아래 'PDF' 글자 (아주 작은 크기는 생략)
    if px >= 32 {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let font = NSFont.systemFont(ofSize: s * 0.13, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                    .foregroundColor: NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.16, alpha: 1)]
        ("PDF" as NSString).draw(in: CGRect(x: page.minX, y: page.minY + ph * 0.07, width: pw, height: s * 0.17), withAttributes: attrs)
    } else {
        // 16px: 빨간 띠로 PDF임을 표시
        ctx.setFillColor(NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.16, alpha: 1).cgColor)
        ctx.fill(CGRect(x: page.minX + pw * 0.15, y: page.minY + ph * 0.2, width: pw * 0.7, height: ph * 0.18))
    }

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("▶ PDF 문서 아이콘 생성")
