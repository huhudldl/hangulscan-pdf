import AppKit
// 사용법: swift make_icon.swift <출력 iconset 폴더> [원본 이미지]
// 원본 이미지가 있으면 그것으로(바깥 흰 배경은 투명 처리), 없으면 기본 아이콘을 그린다.
let out = CommandLine.arguments[1]
let sizes = [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)]

func sourceImage(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    // 가운데 정사각형으로 자르기
    let side = min(cg.width, cg.height)
    guard let sq = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return nil }
    // RGBA 버퍼로 옮긴 뒤, 네 모서리에서 이어진 '거의 흰색' 영역을 투명하게 (둥근 모서리 바깥)
    let n = side
    var px = [UInt8](repeating: 0, count: n * n * 4)
    let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(sq, in: CGRect(x: 0, y: 0, width: n, height: n))
    func nearWhite(_ i: Int) -> Bool { px[i * 4] > 238 && px[i * 4 + 1] > 238 && px[i * 4 + 2] > 238 }
    var seen = [Bool](repeating: false, count: n * n)
    var stack = [0, n - 1, (n - 1) * n, n * n - 1].filter { nearWhite($0) }
    stack.forEach { seen[$0] = true }
    while let p = stack.popLast() {
        px[p * 4] = 0; px[p * 4 + 1] = 0; px[p * 4 + 2] = 0; px[p * 4 + 3] = 0
        let x = p % n, y = p / n
        for q in [x > 0 ? p - 1 : -1, x < n - 1 ? p + 1 : -1, y > 0 ? p - n : -1, y < n - 1 ? p + n : -1] where q >= 0 && !seen[q] && nearWhite(q) {
            seen[q] = true; stack.append(q)
        }
    }
    return ctx.makeImage()
}

func drawDefault(_ s: CGFloat) {
    let bg = NSBezierPath(roundedRect: NSRect(x: s*0.1, y: s*0.1, width: s*0.8, height: s*0.8), xRadius: s*0.18, yRadius: s*0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.86, green: 0.12, blue: 0.16, alpha: 1), ending: NSColor(calibratedRed: 0.62, green: 0.05, blue: 0.12, alpha: 1))!.draw(in: bg, angle: -90)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: s*0.28, y: s*0.22, width: s*0.44, height: s*0.56), xRadius: s*0.03, yRadius: s*0.03).fill()
    let para = NSMutableParagraphStyle(); para.alignment = .center
    ("한" as NSString).draw(in: NSRect(x: s*0.28, y: s*0.36, width: s*0.44, height: s*0.3), withAttributes: [.font: NSFont.systemFont(ofSize: s*0.24, weight: .heavy), .foregroundColor: NSColor(calibratedRed: 0.75, green: 0.08, blue: 0.14, alpha: 1), .paragraphStyle: para])
}

let src = CommandLine.arguments.count > 2 ? sourceImage(CommandLine.arguments[2]) : nil
if CommandLine.arguments.count > 2 && src == nil { print("⚠️ 아이콘 이미지를 읽지 못해 기본 아이콘을 씁니다") }
for (name, px) in sizes {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let src {
        let c = NSGraphicsContext.current!.cgContext
        c.interpolationQuality = .high
        c.draw(src, in: CGRect(x: 0, y: 0, width: s, height: s))
    } else {
        drawDefault(s)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print(src != nil ? "▶ 사용자 아이콘 적용" : "▶ 기본 아이콘 사용")
