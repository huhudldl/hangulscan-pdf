import AppKit
import PDFKit
// 테스트 이미지 만들기: swift scripts/make_test_assets.swift <출력 폴더>
// 기울어진 문서, 사진 속 문서, 90°/180° 회전, 책 펼침, 한국어 표, 이미지뿐인 A4 PDF

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let docText = """
대한민국 헌법 제1조
① 대한민국은 민주공화국이다.
② 대한민국의 주권은 국민에게 있고, 모든 권력은 국민으로부터 나온다.
제10조 모든 국민은 인간으로서의 존엄과 가치를 가지며,
행복을 추구할 권리를 가진다. 국가는 개인이 가지는
불가침의 기본적 인권을 확인하고 이를 보장할 의무를 진다.
OCR 테스트 문서 2026년 10월 16일 — Hangul Scan PDF
"""

func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ name: String) {
    let type: NSBitmapImageRep.FileType = name.hasSuffix(".jpg") ? .jpeg : .png
    try! rep.representation(using: type, properties: [.compressionFactor: 0.9])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

/// 흰 종이 한 장 (1240×1754)
let page: NSImage = {
    let img = NSImage(size: NSSize(width: 1240, height: 1754))
    img.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1240, height: 1754).fill()
    let p = NSMutableParagraphStyle(); p.lineSpacing = 18
    (docText as NSString).draw(in: NSRect(x: 110, y: 200, width: 1040, height: 1400),
                               withAttributes: [.font: NSFont(name: "AppleMyungjo", size: 40)!, .foregroundColor: NSColor.black, .paragraphStyle: p])
    img.unlockFocus()
    return img
}()

func placed(_ w: Int, _ h: Int, bg: NSColor, angle: CGFloat, scale: CGFloat, _ name: String) {
    save(bitmap(w, h) { c in
        c.setFillColor(bg.cgColor); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2); c.rotate(by: angle * .pi / 180); c.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        page.draw(in: NSRect(x: -620, y: -877, width: 1240, height: 1754))
    }, name)
}
placed(1240, 1754, bg: .white, angle: 3.5, scale: 1, "skew35.png")
placed(1800, 2000, bg: NSColor(calibratedRed: 0.25, green: 0.2, blue: 0.15, alpha: 1), angle: -7, scale: 0.85, "photo_m7.png")
placed(1754, 1240, bg: .white, angle: 91.5, scale: 1, "rot90.png")
placed(1754, 1240, bg: .white, angle: -88, scale: 1, "rotm90.png")
placed(1240, 1754, bg: .white, angle: 182, scale: 1, "rot180.png")

// 한국어 표 (교회 행사 일정표 형식)
let rows = [["날짜", "행사", "장소", "담당"],
            ["10월 6일", "가을 소풍", "한강공원", "김민준"],
            ["10월 13일", "성경 퀴즈", "본당 2층", "이서연"],
            ["10월 20일", "찬양 발표회", "유년부실", "박지호"],
            ["10월 27일", "추수감사 예배", "본당", "최수아"]]
save(bitmap(1600, 1100) { c in
    c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1100))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    ("2026년 10월 유년부 행사 일정" as NSString).draw(at: NSPoint(x: 120, y: 940),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.black])
    let x0: CGFloat = 120, colW: [CGFloat] = [300, 420, 360, 280], rowH: CGFloat = 120, top: CGFloat = 860
    c.setStrokeColor(NSColor.black.cgColor); c.setLineWidth(3)
    for r in 0...rows.count { c.move(to: CGPoint(x: x0, y: top - CGFloat(r) * rowH)); c.addLine(to: CGPoint(x: x0 + colW.reduce(0, +), y: top - CGFloat(r) * rowH)) }
    var x = x0
    for k in 0...colW.count { c.move(to: CGPoint(x: x, y: top)); c.addLine(to: CGPoint(x: x, y: top - CGFloat(rows.count) * rowH)); if k < colW.count { x += colW[k] } }
    c.strokePath()
    for (r, row) in rows.enumerated() {
        var cx = x0
        for (k, cell) in row.enumerated() {
            (cell as NSString).draw(at: NSPoint(x: cx + 28, y: top - CGFloat(r + 1) * rowH + 38),
                withAttributes: [.font: r == 0 ? NSFont.boldSystemFont(ofSize: 40) : NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            cx += colW[k]
        }
    }
}, "table.png")

// 이미지뿐인 A4 PDF 12쪽 (텍스트 없음)
let names = ["skew35", "photo_m7", "rot90", "rotm90", "rot180", "skew35"]
let data = NSMutableData()
var box = CGRect(x: 0, y: 0, width: 595, height: 842)
let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
for i in 0..<12 {
    let img = NSImage(contentsOfFile: "\(outDir)/\(names[i % 6]).png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    ctx.beginPDFPage(nil)
    let s = min(595 / CGFloat(img.width), 842 / CGFloat(img.height))
    let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
    ctx.draw(img, in: CGRect(x: (595 - w) / 2, y: (842 - h) / 2, width: w, height: h))
    ctx.endPDFPage()
}
ctx.closePDF()
try! (data as Data).write(to: URL(fileURLWithPath: "\(outDir)/a4_12.pdf"))
print("테스트 이미지 생성: \(outDir)")
